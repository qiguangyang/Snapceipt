import { env, SELF } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as emailModule from "../src/lib/email";

// Migrations are applied by the shared setup file (test/apply-migrations.ts).

// sha256 hex helper mirroring the route's KV-key derivation, used to assert the
// KV write under ml:<sha256(token)>.
async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Spy on the email seam (src/lib/email.ts) so the route doesn't hit the real
 * SendEmail binding (not exercisable in the vitest-pool-workers runtime — same
 * as the AI binding). vi.spyOn on a module shared by both the test and the
 * worker isolate lets us assert the call AND capture the magic-link token from
 * the `link` argument the route passes in. Cleared via afterEach.
 */
function installEmailSpy() {
  const send = vi.spyOn(emailModule, "sendMagicLinkEmail").mockResolvedValue(undefined);
  return {
    send,
    lastToken() {
      const arg = send.mock.calls.at(-1)?.[1] as { link?: string } | undefined;
      const m = String(arg?.link ?? "").match(/token=([A-Za-z0-9_-]+)/);
      if (!m) throw new Error("no token in email payload");
      return m[1]!;
    },
  };
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe("POST /auth/magic-link/request", () => {
  beforeEach(async () => {
    await env.DB.exec("DELETE FROM email_tokens");
  });

  it("returns 202 with no error body, writes ml:<hash> to KV, and calls EMAIL.send", async () => {
    const spy = installEmailSpy();
    const res = await SELF.fetch("https://x/auth/magic-link/request", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: "Maya@Example.com " }),
    });

    expect(res.status).toBe(202);
    expect(spy.send).toHaveBeenCalledTimes(1);

    const token = spy.lastToken();
    const hash = await sha256Hex(token);
    const stored = await env.KV.getWithMetadata(`ml:${hash}`);
    expect(stored.value).not.toBeNull();
    expect(stored.metadata).toMatchObject({ email: "maya@example.com" });
  });

  it("returns 202 even for a syntactically valid but unknown email (no enumeration)", async () => {
    const spy = installEmailSpy();
    const res = await SELF.fetch("https://x/auth/magic-link/request", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: "nobody@example.com" }),
    });
    expect(res.status).toBe(202);
    expect(spy.send).toHaveBeenCalledTimes(1);
  });

  it("rejects a malformed email with 400 VALIDATION_FAILED", async () => {
    installEmailSpy();
    const res = await SELF.fetch("https://x/auth/magic-link/request", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: "not-an-email" }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("VALIDATION_FAILED");
  });
});

describe("POST /auth/magic-link/verify", () => {
  beforeEach(async () => {
    await env.DB.exec("DELETE FROM sessions");
    await env.DB.exec("DELETE FROM auth_identities");
    await env.DB.exec("DELETE FROM devices");
    await env.DB.exec("DELETE FROM users");
  });

  async function requestLink(email: string): Promise<string> {
    const spy = installEmailSpy();
    const res = await SELF.fetch("https://x/auth/magic-link/request", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email }),
    });
    expect(res.status).toBe(202);
    return spy.lastToken();
  }

  it("consumes the token: creates user + session and returns tokens", async () => {
    const token = await requestLink("liam@example.com");
    const res = await SELF.fetch("https://x/auth/magic-link/verify", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-device-id": "01890000-0000-7000-8000-000000000abc",
      },
      body: JSON.stringify({ token }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      accessToken: string;
      refreshToken: string;
      expiresIn: number;
      error?: unknown;
      user: { id: string; email: string; displayName: string | null };
    };
    // Success bodies are unwrapped (no { error } wrapper).
    expect(body.error).toBeUndefined();
    expect(body.expiresIn).toBe(900);
    expect(body.accessToken.split(".")).toHaveLength(3); // JWT
    expect(body.refreshToken.length).toBeGreaterThanOrEqual(40);
    expect(body.user.email).toBe("liam@example.com");

    const user = await env.DB.prepare("SELECT id FROM users WHERE email = ?")
      .bind("liam@example.com")
      .first();
    expect(user).not.toBeNull();
    const ident = await env.DB
      .prepare("SELECT id FROM auth_identities WHERE provider = 'email' AND subject = ?")
      .bind("liam@example.com")
      .first();
    expect(ident).not.toBeNull();
    const device = await env.DB
      .prepare("SELECT id FROM devices WHERE id = ?")
      .bind("01890000-0000-7000-8000-000000000abc")
      .first();
    expect(device).not.toBeNull();
  });

  it("reuses the existing user on a second magic-link sign-in (no duplicate)", async () => {
    const t1 = await requestLink("repeat@example.com");
    const r1 = await SELF.fetch("https://x/auth/magic-link/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ token: t1 }),
    });
    expect(r1.status).toBe(200);
    const u1 = (await r1.json()) as { user: { id: string } };

    const t2 = await requestLink("repeat@example.com");
    const r2 = await SELF.fetch("https://x/auth/magic-link/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ token: t2 }),
    });
    expect(r2.status).toBe(200);
    const u2 = (await r2.json()) as { user: { id: string } };

    expect(u2.user.id).toBe(u1.user.id);
    const rows = await env.DB.prepare("SELECT COUNT(*) AS n FROM users WHERE email = ?")
      .bind("repeat@example.com")
      .first<{ n: number }>();
    expect(rows!.n).toBe(1);
  });

  it("rejects a second use of the same token with 401 (single-use)", async () => {
    const token = await requestLink("twice@example.com");
    const ok = await SELF.fetch("https://x/auth/magic-link/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ token }),
    });
    expect(ok.status).toBe(200);

    const replay = await SELF.fetch("https://x/auth/magic-link/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ token }),
    });
    expect(replay.status).toBe(401);
    const body = (await replay.json()) as { error: { code: string } };
    expect(body.error.code).toBe("AUTH_INVALID_TOKEN");
  });

  it("rejects an unknown / expired token with 401", async () => {
    const res = await SELF.fetch("https://x/auth/magic-link/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ token: "totally-made-up-token" }),
    });
    expect(res.status).toBe(401);
  });
});

describe("GET /auth/magic (bridge)", () => {
  it("serves an HTML page that forwards a valid token to the snapceipt:// scheme", async () => {
    const res = await SELF.fetch("https://x/auth/magic?token=abc123_TOK-en");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/html");
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(res.headers.get("referrer-policy")).toBe("no-referrer");
    const html = await res.text();
    expect(html).toContain("snapceipt://auth/verify?token=abc123_TOK-en");
  });

  it("returns 400 and does NOT emit a scheme link when the token is missing", async () => {
    const res = await SELF.fetch("https://x/auth/magic");
    expect(res.status).toBe(400);
    const html = await res.text();
    expect(html).not.toContain("snapceipt://auth/verify");
  });

  it("returns 400 when the token contains non-base64url characters", async () => {
    const res = await SELF.fetch("https://x/auth/magic?token=bad%20token%3Cscript%3E");
    expect(res.status).toBe(400);
    const html = await res.text();
    expect(html).not.toContain("snapceipt://auth/verify");
  });
});
