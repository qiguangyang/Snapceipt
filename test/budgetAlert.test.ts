import { env, applyD1Migrations } from "cloudflare:test";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import * as apns from "../src/lib/apns";
import { budgetCronLogic } from "../src/cron/budgetAlert";
import type { Env } from "../src/env";

declare module "cloudflare:test" {
  // Extend our src/env.ts Env so the typed `env` satisfies budgetCronLogic(env.DB, env, ...).
  interface ProvidedEnv extends Env {
    TEST_MIGRATIONS: Parameters<typeof applyD1Migrations>[1];
  }
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

afterEach(() => {
  vi.restoreAllMocks();
});

const U = "ucron";
const P = "pcron";
const D = "dcron";
// 2026-05-15 06:00:00 UTC — a deterministic "now" for the cron.
const NOW = Date.UTC(2026, 4, 15, 6, 0, 0);

async function seedBase(): Promise<void> {
  await env.DB.exec("DELETE FROM transactions");
  await env.DB.exec("DELETE FROM budgets");
  await env.DB.exec("DELETE FROM devices");
  await env.DB.exec("DELETE FROM profiles");
  await env.DB.exec("DELETE FROM categories");
  await env.DB.exec("DELETE FROM users");
  await env.DB.batch([
    env.DB.prepare(`INSERT INTO users(id,created_at,updated_at) VALUES(?,1,1)`).bind(U),
    env.DB.prepare(
      `INSERT INTO profiles(id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
       VALUES(?,?,'Personal','personal','#0E7C72','#DCF0ED','#0A5950',1,1)`,
    ).bind(P, U),
    env.DB.prepare(
      `INSERT INTO devices(id,user_id,platform,apns_token,push_enabled,created_at,updated_at)
       VALUES(?,?,'ios','tok-hex',1,1,1)`,
    ).bind(D, U),
  ]);
}

async function addTxn(id: string, cents: number, date: string, categoryId: string | null): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO transactions(id,user_id,profile_id,cat_key,amount_cents,txn_date,category_id,created_at,updated_at)
     VALUES(?,?,?,'meals',?,?,?,1,1)`,
  )
    .bind(id, U, P, cents, date, categoryId)
    .run();
}

async function addBudget(
  id: string,
  opts: { categoryId?: string | null; capCents: number; thresholdPct?: number; alertSentAt?: number | null; monthKey?: string | null },
): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO budgets(id,user_id,profile_id,category_id,label,period,month_key,cap_cents,alert_threshold_pct,alert_sent_at,created_at,updated_at)
     VALUES(?,?,?,?,?,'monthly',?,?,?,?,1,1)`,
  )
    .bind(
      id,
      U,
      P,
      opts.categoryId ?? null,
      "Meals",
      opts.monthKey ?? null,
      opts.capCents,
      opts.thresholdPct ?? 90,
      opts.alertSentAt ?? null,
    )
    .run();
}

async function alertSentAt(budgetId: string): Promise<number | null> {
  const row = await env.DB.prepare(`SELECT alert_sent_at FROM budgets WHERE id=?`)
    .bind(budgetId)
    .first<{ alert_sent_at: number | null }>();
  return row?.alert_sent_at ?? null;
}

beforeEach(seedBase);

describe("budgetCronLogic", () => {
  it("fires for a whole-profile budget when month spend crosses the threshold; payload asserted", async () => {
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: false, status: 200 });
    await addBudget("bw", { categoryId: null, capCents: 10000, thresholdPct: 90 });
    await addTxn("t1", -6000, "2026-05-03", null);
    await addTxn("t2", -3000, "2026-05-10", null);
    // Income / positive amounts are ignored.
    await addTxn("t3", 5000, "2026-05-11", null);

    await budgetCronLogic(env.DB, env, NOW);

    expect(spy).toHaveBeenCalledTimes(1);
    const [, token, payload] = spy.mock.calls[0]!;
    expect(token).toBe("tok-hex");
    expect(payload.budgetId).toBe("bw");
    expect(payload.deepLink).toBe("snapceipt://budget/bw");
    expect(payload.aps.alert.title).toBe("Budget alert");
    expect(payload.aps.alert.body).toBe("Meals: $90.00 of $100.00 (90%)");
    expect(await alertSentAt("bw")).toBe(NOW);
  });

  it("scopes spend per category for a per-category budget", async () => {
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: true });
    await env.DB.prepare(
      `INSERT INTO categories(id,user_id,profile_id,key,label,icon,tint,soft,created_at,updated_at)
       VALUES('cat1',?,?,'meals','Meals','fork','#111','#222',1,1)`,
    ).bind(U, P).run();
    await addBudget("bc", { categoryId: "cat1", capCents: 10000, thresholdPct: 90 });
    await addTxn("t1", -9500, "2026-05-03", "cat1"); // counts
    await addTxn("t2", -9000, "2026-05-04", null);   // other category — ignored

    await budgetCronLogic(env.DB, env, NOW);

    expect(spy).toHaveBeenCalledTimes(1);
    expect(spy.mock.calls[0]![2].budgetId).toBe("bc");
  });

  it("does NOT fire below threshold", async () => {
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: true });
    await addBudget("bu", { categoryId: null, capCents: 10000, thresholdPct: 90 });
    await addTxn("t1", -8000, "2026-05-03", null); // 80% < 90%

    await budgetCronLogic(env.DB, env, NOW);

    expect(spy).not.toHaveBeenCalled();
    expect(await alertSentAt("bu")).toBeNull();
  });

  it("dedups: a same-month alert_sent_at suppresses a re-send", async () => {
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: true });
    const earlierThisMonth = Date.UTC(2026, 4, 12, 0, 0, 0);
    await addBudget("bd", { categoryId: null, capCents: 10000, alertSentAt: earlierThisMonth });
    await addTxn("t1", -9500, "2026-05-03", null);

    await budgetCronLogic(env.DB, env, NOW);

    expect(spy).not.toHaveBeenCalled();
    expect(await alertSentAt("bd")).toBe(earlierThisMonth); // unchanged
  });

  it("re-arms after a month rollover (alert_sent_at in a prior month)", async () => {
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: false, status: 200 });
    const lastMonth = Date.UTC(2026, 3, 20, 0, 0, 0); // 2026-04
    await addBudget("br", { categoryId: null, capCents: 10000, alertSentAt: lastMonth });
    await addTxn("t1", -9500, "2026-05-03", null);

    await budgetCronLogic(env.DB, env, NOW);

    expect(spy).toHaveBeenCalledTimes(1);
    expect(await alertSentAt("br")).toBe(NOW);
  });

  it("suppresses pushes during quiet hours and leaves alert_sent_at unset", async () => {
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: true });
    // NOW = 06:00 UTC = 16:00 Australia/Sydney (UTC+10, no DST in May).
    // Quiet window 15:00 (900) -> 17:00 (1020) covers 16:00 -> suppressed.
    await env.DB.prepare(
      `UPDATE devices SET timezone='Australia/Sydney', quiet_hours_start_min=900, quiet_hours_end_min=1020 WHERE id=?`,
    ).bind(D).run();
    await addBudget("bq", { categoryId: null, capCents: 10000 });
    await addTxn("t1", -9500, "2026-05-03", null);

    await budgetCronLogic(env.DB, env, NOW);

    expect(spy).not.toHaveBeenCalled();
    expect(await alertSentAt("bq")).toBeNull(); // not set — next run outside quiet hours delivers
  });

  it("delivers when the device is OUTSIDE its wrap-around quiet window", async () => {
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: false, status: 200 });
    // 16:00 Sydney with a 22:00 (1320) -> 07:00 (420) wrap window: 16:00 is awake.
    await env.DB.prepare(
      `UPDATE devices SET timezone='Australia/Sydney', quiet_hours_start_min=1320, quiet_hours_end_min=420 WHERE id=?`,
    ).bind(D).run();
    await addBudget("bw2", { categoryId: null, capCents: 10000 });
    await addTxn("t1", -9500, "2026-05-03", null);

    await budgetCronLogic(env.DB, env, NOW);

    expect(spy).toHaveBeenCalledTimes(1);
    expect(await alertSentAt("bw2")).toBe(NOW);
  });

  it("skips devices with push_enabled=0 or a null apns_token", async () => {
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: true });
    await env.DB.prepare(`UPDATE devices SET push_enabled=0 WHERE id=?`).bind(D).run();
    // A second device with no token.
    await env.DB.prepare(
      `INSERT INTO devices(id,user_id,platform,apns_token,push_enabled,created_at,updated_at)
       VALUES('d2',?,'ios',NULL,1,1,1)`,
    ).bind(U).run();
    await addBudget("bf", { categoryId: null, capCents: 10000 });
    await addTxn("t1", -9500, "2026-05-03", null);

    await budgetCronLogic(env.DB, env, NOW);

    expect(spy).not.toHaveBeenCalled();
    expect(await alertSentAt("bf")).toBeNull(); // no device pushed -> unset
  });

  it("a throwing sendPush for one device does not abort the run; remaining devices are still attempted", async () => {
    // Seed a second device alongside the existing one (D has token 'tok-hex').
    await env.DB.prepare(
      `INSERT INTO devices(id,user_id,platform,apns_token,push_enabled,created_at,updated_at)
       VALUES('d2',?,'ios','tok-second',1,1,1)`,
    ).bind(U).run();

    await addBudget("berr", { categoryId: null, capCents: 10000, thresholdPct: 90 });
    await addTxn("t1", -9500, "2026-05-03", null);

    // First token throws (e.g. expired APNs token); second succeeds.
    const spy = vi.spyOn(apns, "sendPush").mockImplementation((_env, token, _payload) => {
      if (token === "tok-hex") return Promise.reject(new Error("APNs 410 Gone"));
      return Promise.resolve({ stub: false, status: 200 });
    });

    // Must not throw out of budgetCronLogic.
    await expect(budgetCronLogic(env.DB, env, NOW)).resolves.toBeUndefined();

    // Both devices were attempted.
    expect(spy).toHaveBeenCalledTimes(2);

    // Second device succeeded -> pushed > 0 -> alert_sent_at is stamped.
    expect(await alertSentAt("berr")).toBe(NOW);
  });

  it("stub-mode sendPush (no APNS_KEY) does NOT stamp alert_sent_at", async () => {
    // No mock: the real apns.sendPush runs and returns { stub: true } because the
    // test env has no APNS_KEY bound. A stub is NOT a real delivery, so the budget
    // must stay re-armed for the next run once the key is provisioned.
    const spy = vi.spyOn(apns, "sendPush");
    await addBudget("bstub", { categoryId: null, capCents: 10000, thresholdPct: 90 });
    await addTxn("t1", -9500, "2026-05-03", null);

    await budgetCronLogic(env.DB, env, NOW);

    expect(spy).toHaveBeenCalledTimes(1);
    expect((await spy.mock.results[0]!.value)).toEqual({ stub: true });
    expect(await alertSentAt("bstub")).toBeNull();
  });

  it("a non-2xx APNs status does NOT stamp alert_sent_at", async () => {
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: false, status: 503 });
    await addBudget("b503", { categoryId: null, capCents: 10000, thresholdPct: 90 });
    await addTxn("t1", -9500, "2026-05-03", null);

    await budgetCronLogic(env.DB, env, NOW);

    expect(spy).toHaveBeenCalledTimes(1);
    expect(await alertSentAt("b503")).toBeNull(); // 503 is not a delivery -> re-arm next run
  });
});
