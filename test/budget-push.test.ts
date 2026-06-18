import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { signAccess } from "../src/lib/jwt";
import { uuidv7 } from "../src/lib/ids";

const USER_ID = "01890000-0000-7000-8000-000000000001";
const DEVICE_ID = "01890000-0000-7000-8000-0000000000d1";
const PROFILE_ID = "01890000-0000-7000-8000-0000000000a1";
const SESSION_ID = "01890000-0000-7000-8000-0000000000c1";
const CAT_ID = "01890000-0000-7000-8000-0000000000e1";

async function seedUserAndProfile() {
  const now = Date.now();
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, ?, 1, 'free', ?, ?)`,
  ).bind(USER_ID, "maya@example.com", now, now).run();
  await env.DB.prepare(
    `INSERT INTO profiles (id, user_id, name, type, accent_1, accent_2, accent_3, sort_order, is_default, created_at, updated_at, rev)
     VALUES (?, ?, 'Personal', 'personal', '#000', '#111', '#222', 0, 1, ?, ?, 1)`,
  ).bind(PROFILE_ID, USER_ID, now, now).run();
}

async function authHeader() {
  const token = await signAccess(env.JWT_SIGNING_KEY, { userId: USER_ID, sessionId: SESSION_ID, deviceId: DEVICE_ID });
  return { Authorization: `Bearer ${token}`, "Content-Type": "application/json" };
}

function categoryMutation() {
  return {
    mutationId: uuidv7(),
    entityType: "category",
    entityId: CAT_ID,
    op: "upsert" as const,
    updatedAt: 1_000,
    payload: {
      id: CAT_ID, userId: USER_ID, profileId: PROFILE_ID, type: "category",
      createdAt: 1_000, updatedAt: 1_000, deletedAt: null, rev: 0, lastEditedDeviceId: DEVICE_ID,
      key: "groceries", label: "Groceries", icon: "cart", tint: "#000", soft: "#111",
    } as Record<string, unknown>,
  };
}

function budgetMutation(payloadOverrides: Record<string, unknown> = {}) {
  const entityId = uuidv7();
  return {
    mutationId: uuidv7(),
    entityType: "budget",
    entityId,
    op: "upsert" as const,
    updatedAt: 1_000,
    payload: {
      id: entityId, userId: USER_ID, profileId: PROFILE_ID, type: "budget",
      createdAt: 1_000, updatedAt: 1_000, deletedAt: null, rev: 0, lastEditedDeviceId: DEVICE_ID,
      label: "Groceries", period: "monthly", capCents: 50_000, currency: "AUD", alertThresholdPct: 90,
      ...payloadOverrides,
    } as Record<string, unknown>,
  };
}

async function push(body: unknown) {
  return SELF.fetch("https://api.snapceipt.cc/sync/push", {
    method: "POST", headers: await authHeader(), body: JSON.stringify(body),
  });
}

describe("POST /sync/push — budgets", () => {
  beforeEach(async () => {
    await env.DB.exec("DELETE FROM processed_mutations");
    await env.DB.exec("DELETE FROM budgets");
    await env.DB.exec("DELETE FROM categories");
    await env.DB.exec("DELETE FROM profiles");
    await env.DB.exec("DELETE FROM users");
    await seedUserAndProfile();
  });

  it("applies a whole-profile budget (null category)", async () => {
    const res = await push({ deviceId: DEVICE_ID, mutations: [budgetMutation()] });
    expect(res.status).toBe(200);
    const json = (await res.json()) as any;
    expect(json.results[0].status).toBe("applied");
  });

  it("applies a category budget when its category is pushed first (the launch-seed ordering)", async () => {
    const cat = categoryMutation();
    const bud = budgetMutation({ categoryId: CAT_ID, catKey: "groceries" });
    const res = await push({ deviceId: DEVICE_ID, mutations: [cat, bud] });
    expect(res.status).toBe(200);
    const json = (await res.json()) as any;
    expect(json.results[0].status).toBe("applied"); // category
    expect(json.results[1].status).toBe("applied"); // budget references it → FK satisfied
  });

  it("rejects (does NOT 500) a category budget whose category is missing on the server", async () => {
    const res = await push({ deviceId: DEVICE_ID, mutations: [budgetMutation({ categoryId: CAT_ID, catKey: "groceries" })] });
    // The FK violation must reject only this mutation, not 500 the whole push (which
    // would make the client silently go offline).
    expect(res.status).toBe(200);
    const json = (await res.json()) as any;
    expect(json.results[0].status).toBe("rejected");
  });
});
