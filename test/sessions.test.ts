import { describe, it, expect, beforeEach } from "vitest";
import { env } from "cloudflare:test";
import { nowMs } from "../src/lib/time";
import { hashToken, verifyAccess } from "../src/lib/jwt";
import {
  issueSession,
  findSessionByRefreshHash,
  rotateSession,
  revokeSession,
  revokeSessionFamily,
} from "../src/lib/sessions";

const USER_ID = "u-sess-1";
const DEVICE_ID = "d-sess-1";

// issueSession mints the access token (Canonical Contracts), so it needs the
// HS256 signing key alongside the identity fields.
function issueArgs() {
  return { userId: USER_ID, deviceId: DEVICE_ID, signingKey: env.JWT_SIGNING_KEY };
}

beforeEach(async () => {
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM users");
  const t = nowMs();
  await env.DB.prepare(
    "INSERT INTO users (id, email, email_verified, display_name, plan, created_at, updated_at) VALUES (?, ?, 0, ?, 'free', ?, ?)",
  )
    .bind(USER_ID, "sess@example.com", "Sess User", t, t)
    .run();
});

describe("sessions", () => {
  it("creates a session, persists the refresh hash, and finds it back", async () => {
    const { sessionId, refreshToken } = await issueSession(env.DB, issueArgs());
    expect(sessionId).toBeTruthy();
    expect(refreshToken).toBeTruthy();

    const found = await findSessionByRefreshHash(env.DB, await hashToken(refreshToken));
    expect(found).not.toBeNull();
    expect(found!.id).toBe(sessionId);
    expect(found!.user_id).toBe(USER_ID);
    expect(found!.device_id).toBe(DEVICE_ID);
    expect(found!.revoked_at).toBeNull();
    expect(found!.family).toBeTruthy();
    expect(found!.expires_at).toBeGreaterThan(nowMs());
  });

  it("mints a valid access token bound to the session id and the documented TTL", async () => {
    // Canonical Contracts: issueSession returns { accessToken, refreshToken, expiresIn, sessionId, family }.
    const { accessToken, expiresIn, sessionId } = await issueSession(env.DB, issueArgs());
    expect(accessToken).toBeTruthy();
    expect(expiresIn).toBe(900);

    const claims = await verifyAccess(env.JWT_SIGNING_KEY, accessToken);
    expect(claims.sub).toBe(USER_ID);
    expect(claims.sid).toBe(sessionId);
    expect(claims.did).toBe(DEVICE_ID);
  });

  it("rotates: old refresh hash stops resolving, new one resolves to the same family", async () => {
    const { sessionId, refreshToken, family } = await issueSession(env.DB, issueArgs());
    const oldHash = await hashToken(refreshToken);

    const rotated = await rotateSession(env.DB, sessionId);
    const newHash = await hashToken(rotated.refreshToken);
    expect(newHash).not.toBe(oldHash);

    // old hash no longer matches a live session
    expect(await findSessionByRefreshHash(env.DB, oldHash)).toBeNull();
    // new hash resolves to the same row + same family
    const live = await findSessionByRefreshHash(env.DB, newHash);
    expect(live).not.toBeNull();
    expect(live!.id).toBe(sessionId);
    expect(live!.family).toBe(family);
  });

  it("revokeSession marks the row revoked so it stops resolving", async () => {
    const { sessionId, refreshToken } = await issueSession(env.DB, issueArgs());
    await revokeSession(env.DB, sessionId);
    expect(await findSessionByRefreshHash(env.DB, await hashToken(refreshToken))).toBeNull();
  });

  it("revokeSessionFamily revokes every session sharing the family (reuse detection)", async () => {
    const s1 = await issueSession(env.DB, issueArgs());
    // simulate a rotated descendant in the same family
    const s2 = await rotateSession(env.DB, s1.sessionId);

    await revokeSessionFamily(env.DB, s1.family);

    expect(await findSessionByRefreshHash(env.DB, await hashToken(s2.refreshToken))).toBeNull();
    const row = await env.DB.prepare("SELECT revoked_at FROM sessions WHERE id = ?")
      .bind(s1.sessionId)
      .first<{ revoked_at: number | null }>();
    expect(row!.revoked_at).not.toBeNull();
  });
});
