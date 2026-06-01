import { env, SELF } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as emailModule from "../src/lib/email";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";

// The real EMAIL binding is not exercisable in the vitest-pool-workers runtime
// (same constraint as the AI binding — see test/auth.magiclink.test.ts), so spy
// on the email seam. The 6-digit code only ships back to the client as `devCode`
// under E2E_TEST_MODE (the e2e harness sets it; the unit config deliberately
// leaves it off so integration.test.ts can assert no secret leaks). So in unit
// tests we capture the issued code from the spy's call arg — the same technique
// auth.magiclink.test.ts uses to recover the magic-link token from the email body.
function installEmailSpy() {
  const send = vi.spyOn(emailModule, "sendEmailChangeCode").mockResolvedValue(undefined);
  return {
    send,
    lastCode(): string {
      const arg = send.mock.calls.at(-1)?.[1] as { code?: string } | undefined;
      const code = arg?.code;
      if (!code) throw new Error("no code in email payload");
      return code;
    },
  };
}

afterEach(() => {
  vi.restoreAllMocks();
});

async function seedUser(email = "old@example.com"): Promise<{ userId: string; bearer: string }> {
  const userId = uuidv7();
  const deviceId = uuidv7();
  const t = nowMs();
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, ?, 1, 'free', ?, ?)`,
  ).bind(userId, email, t, t).run();
  await env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at) VALUES (?, ?, 'ios', 1, ?, ?)`,
  ).bind(deviceId, userId, t, t).run();
  const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
  return { userId, bearer: `Bearer ${accessToken}` };
}

beforeEach(async () => {
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM devices");
  await env.DB.exec("DELETE FROM users");
});

describe("POST /users/me/email (+ /verify)", () => {
  it("issues a code and verifying it swaps the email", async () => {
    const spy = installEmailSpy();
    const { userId, bearer } = await seedUser();
    const req = await SELF.fetch("https://x/users/me/email", {
      method: "POST", headers: { authorization: bearer, "content-type": "application/json" },
      body: JSON.stringify({ newEmail: "new@example.com" }),
    });
    expect(req.status).toBe(202);
    const { sent } = (await req.json()) as { sent: boolean; devCode?: string };
    expect(sent).toBe(true);
    expect(spy.send).toHaveBeenCalledTimes(1);
    const code = spy.lastCode();
    expect(code).toMatch(/^\d{6}$/);

    const ver = await SELF.fetch("https://x/users/me/email/verify", {
      method: "POST", headers: { authorization: bearer, "content-type": "application/json" },
      body: JSON.stringify({ code }),
    });
    expect(ver.status).toBe(200);
    expect(((await ver.json()) as any).user.email).toBe("new@example.com");
    const row = await env.DB.prepare("SELECT email FROM users WHERE id = ?").bind(userId).first<{ email: string }>();
    expect(row!.email).toBe("new@example.com");
  });

  it("409s when the new email is already used by another user", async () => {
    installEmailSpy();
    const { bearer } = await seedUser("me@example.com");
    const t = nowMs();
    await env.DB.prepare(`INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, 'taken@example.com', 1, 'free', ?, ?)`).bind(uuidv7(), t, t).run();
    const req = await SELF.fetch("https://x/users/me/email", {
      method: "POST", headers: { authorization: bearer, "content-type": "application/json" },
      body: JSON.stringify({ newEmail: "taken@example.com" }),
    });
    expect(req.status).toBe(409);
  });

  it("400s on a wrong code", async () => {
    installEmailSpy();
    const { bearer } = await seedUser();
    await SELF.fetch("https://x/users/me/email", {
      method: "POST", headers: { authorization: bearer, "content-type": "application/json" },
      body: JSON.stringify({ newEmail: "new@example.com" }),
    });
    const ver = await SELF.fetch("https://x/users/me/email/verify", {
      method: "POST", headers: { authorization: bearer, "content-type": "application/json" },
      body: JSON.stringify({ code: "000000" }),
    });
    // 400 wrong code OR 410 if the random code happened to be 000000 (then it was consumed) — accept either failure
    expect([400, 410]).toContain(ver.status);
  });

  it("burns the code after 5 wrong attempts (brute-force cap -> 410 GONE)", async () => {
    const spy = installEmailSpy();
    const { bearer } = await seedUser();
    await SELF.fetch("https://x/users/me/email", {
      method: "POST", headers: { authorization: bearer, "content-type": "application/json" },
      body: JSON.stringify({ newEmail: "new@example.com" }),
    });
    const realCode = spy.lastCode();
    // Choose a guaranteed-wrong 6-digit code (never equal to the issued one).
    const wrong = realCode === "000000" ? "111111" : "000000";

    const verify = (code: string) =>
      SELF.fetch("https://x/users/me/email/verify", {
        method: "POST", headers: { authorization: bearer, "content-type": "application/json" },
        body: JSON.stringify({ code }),
      });

    // Attempts 1-4: each wrong guess is a 400 VALIDATION_FAILED, code still live.
    for (let i = 1; i <= 4; i++) {
      const r = await verify(wrong);
      expect(r.status).toBe(400);
    }
    // Attempt 5: hits the cap (attempts >= 5) -> code burned, 410 GONE.
    const fifth = await verify(wrong);
    expect(fifth.status).toBe(410);
    expect(((await fifth.json()) as any).error.code).toBe("GONE");

    // Subsequent verify (even with the CORRECT code) is rejected: KV key is gone.
    const after = await verify(realCode);
    expect(after.status).toBe(410);
    expect(((await after.json()) as any).error.code).toBe("GONE");
  });
});
