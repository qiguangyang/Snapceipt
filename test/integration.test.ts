import { env, SELF, applyD1Migrations } from "cloudflare:test";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import * as emailModule from "../src/lib/email";

beforeAll(async () => {
  // Idempotent; keeps the suite self-contained alongside the shared setup file.
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

afterEach(() => {
  vi.restoreAllMocks();
});

const BASE = "https://api.test";

/**
 * Capture the single-use magic-link token by stubbing the email seam (the real
 * SendEmail binding is not exercisable in the vitest-pool-workers runtime). The
 * route passes the fully-formed link (`?token=<token>`) to sendMagicLinkEmail;
 * we read it back from the spy. This is the SPINE-approved alternative to reading
 * the raw token out of KV (the server stores only `ml:<sha256(token)>`).
 */
function installEmailSpy() {
  const send = vi.spyOn(emailModule, "sendMagicLinkEmail").mockResolvedValue(undefined);
  return {
    lastToken(): string {
      const arg = send.mock.calls.at(-1)?.[1] as { link?: string } | undefined;
      const m = String(arg?.link ?? "").match(/token=([A-Za-z0-9_-]+)/);
      if (!m) throw new Error("no magic-link token captured from email send");
      return m[1]!;
    },
  };
}

describe("integration: magic-link -> sync push/pull, banks 501, health 200", () => {
  it("GET /health returns 200", async () => {
    const res = await SELF.fetch(`${BASE}/health`);
    expect(res.status).toBe(200);
    const body = (await res.json()) as { ok: boolean };
    expect(body.ok).toBe(true);
  });

  it("ALL /banks returns 501 NOT_IMPLEMENTED", async () => {
    const res = await SELF.fetch(`${BASE}/banks`);
    expect(res.status).toBe(501);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("NOT_IMPLEMENTED");
  });

  it("signs in via magic-link, pushes a transaction, and pulls it back", async () => {
    const spy = installEmailSpy();
    const email = "integration@example.com";
    const ip = "198.51.100.7";
    const jsonHeaders = { "content-type": "application/json", "cf-connecting-ip": ip };

    // 1. Request the magic link (email send is stubbed; always 202).
    const reqRes = await SELF.fetch(`${BASE}/auth/magic-link/request`, {
      method: "POST",
      headers: jsonHeaders,
      body: JSON.stringify({ email }),
    });
    expect(reqRes.status).toBe(202);
    // E2E seam is GATED OFF by default: the workers-pool runtime does not set
    // E2E_TEST_MODE, so the 202 carries NO body and never leaks the raw token.
    // (The e2e harness sets E2E_TEST_MODE="1" to opt into the `{ devToken }` body.)
    const reqText = await reqRes.text();
    expect(reqText).toBe("");
    expect(reqText).not.toContain("devToken");

    // 2. Recover the single-use token from the captured email, then verify.
    const token = spy.lastToken();
    const verifyRes = await SELF.fetch(`${BASE}/auth/magic-link/verify`, {
      method: "POST",
      headers: jsonHeaders,
      body: JSON.stringify({ token }),
    });
    expect(verifyRes.status).toBe(200);
    const session = (await verifyRes.json()) as {
      accessToken: string;
      refreshToken: string;
      expiresIn: number;
      user: { id: string; email: string };
    };
    expect(session.accessToken).toBeTruthy();
    expect(session.refreshToken).toBeTruthy();
    expect(session.expiresIn).toBe(900);
    expect(session.user.email).toBe(email);

    const authHeaders = {
      "content-type": "application/json",
      authorization: `Bearer ${session.accessToken}`,
    };
    const deviceId = crypto.randomUUID();
    const profileId = crypto.randomUUID();
    const txnId = crypto.randomUUID();
    const profileMutationId = crypto.randomUUID();
    const txnMutationId = crypto.randomUUID();
    const clientUpdatedAt = Date.now();

    // 3a. Push a profile first so the transaction's profile_id FK is satisfied
    //     (transactions.profile_id is NOT NULL REFERENCES profiles(id)).
    const pushProfileRes = await SELF.fetch(`${BASE}/sync/push`, {
      method: "POST",
      headers: authHeaders,
      body: JSON.stringify({
        deviceId,
        mutations: [
          {
            mutationId: profileMutationId,
            entityType: "profile",
            entityId: profileId,
            op: "upsert",
            updatedAt: clientUpdatedAt,
            payload: {
              id: profileId,
              userId: session.user.id,
              type: "profile",
              name: "Business",
              profileType: "business",
              accent1: "#000",
              accent2: "#111",
              accent3: "#222",
              createdAt: clientUpdatedAt,
              updatedAt: clientUpdatedAt,
              deletedAt: null,
              rev: 0,
              lastEditedDeviceId: deviceId,
            },
          },
        ],
      }),
    });
    expect(pushProfileRes.status).toBe(200);
    const pushProfileBody = (await pushProfileRes.json()) as {
      results: { status: string }[];
    };
    expect(pushProfileBody.results[0]?.status).toBe("applied");

    // 3b. Push one transaction. payload.userId MUST equal the authed user (tenancy).
    const txnMutation = {
      mutationId: txnMutationId,
      entityType: "transaction",
      entityId: txnId,
      op: "upsert" as const,
      updatedAt: clientUpdatedAt,
      payload: {
        id: txnId,
        userId: session.user.id,
        profileId,
        type: "transaction",
        merchant: "Test Cafe",
        catKey: "meals",
        amountCents: -1250,
        currency: "AUD",
        txnDate: "2026-05-30",
        mode: "business",
        createdAt: clientUpdatedAt,
        updatedAt: clientUpdatedAt,
        deletedAt: null,
        rev: 0,
        lastEditedDeviceId: deviceId,
      },
    };
    const pushRes = await SELF.fetch(`${BASE}/sync/push`, {
      method: "POST",
      headers: authHeaders,
      body: JSON.stringify({ deviceId, mutations: [txnMutation] }),
    });
    expect(pushRes.status).toBe(200);
    const pushBody = (await pushRes.json()) as {
      results: { mutationId: string; status: string; entity: { id: string; rev: number } }[];
      serverTime: number;
    };
    expect(pushBody.results).toHaveLength(1);
    expect(pushBody.results[0]?.mutationId).toBe(txnMutationId);
    expect(pushBody.results[0]?.status).toBe("applied");
    expect(pushBody.results[0]?.entity.id).toBe(txnId);
    expect(pushBody.results[0]?.entity.rev).toBe(1);

    // 4. Pull from the start (no cursor) and assert the transaction comes back.
    const pullRes = await SELF.fetch(`${BASE}/sync/pull`, { headers: authHeaders });
    expect(pullRes.status).toBe(200);
    const pullBody = (await pullRes.json()) as {
      changes: { id: string; type: string; merchant?: string; rev: number }[];
      nextCursor: string | null;
      hasMore: boolean;
      serverTime: number;
    };
    const pulled = pullBody.changes.find((ch) => ch.id === txnId);
    expect(pulled).toBeDefined();
    expect(pulled?.type).toBe("transaction");
    expect(pulled?.merchant).toBe("Test Cafe");
    expect(pulled?.rev).toBe(1);
    // The profile we pushed first also comes back in the same delta stream.
    expect(pullBody.changes.some((ch) => ch.id === profileId && ch.type === "profile")).toBe(true);

    // 5. Replaying the same transaction mutation is idempotent (duplicate, not a
    //    second row).
    const replayRes = await SELF.fetch(`${BASE}/sync/push`, {
      method: "POST",
      headers: authHeaders,
      body: JSON.stringify({ deviceId, mutations: [txnMutation] }),
    });
    expect(replayRes.status).toBe(200);
    const replayBody = (await replayRes.json()) as { results: { status: string }[] };
    expect(replayBody.results[0]?.status).toBe("duplicate");
  });
});
