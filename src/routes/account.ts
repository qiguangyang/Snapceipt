// src/routes/account.ts
import { Hono } from "hono";
import { z } from "zod";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { nowMs } from "../lib/time";
import { validate } from "./auth";
import { sendEmailChangeCode } from "../lib/email";

/**
 * Account routes (auth-gated; rate tier "account"):
 *  POST /users/me/email         — request a 6-digit code to the NEW address
 *  POST /users/me/email/verify  — confirm the code, swap users.email
 *  DELETE /account              — irreversible hard purge of the user's data (Task 4)
 */
export const accountRoutes = new Hono<AppEnv>();

const EMAIL_CODE_TTL_SECONDS = 600;

function normalizeEmail(e: string): string {
  return e.trim().toLowerCase();
}
async function sha256Hex(input: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function sixDigitCode(): string {
  const n = (crypto.getRandomValues(new Uint32Array(1))[0] ?? 0) % 1_000_000;
  return n.toString().padStart(6, "0");
}

const emailBody = z.object({ newEmail: z.string().email() });
const verifyBody = z.object({ code: z.string().regex(/^\d{6}$/) });

accountRoutes.post("/users/me/email", validate("json", emailBody), async (c) => {
  const userId = c.var.userId;
  const newEmail = normalizeEmail(c.req.valid("json").newEmail);

  const me = await c.env.DB.prepare("SELECT email FROM users WHERE id = ? AND deleted_at IS NULL")
    .bind(userId).first<{ email: string | null }>();
  if (!me) throw new ApiError("NOT_FOUND", "User not found");
  if (me.email && normalizeEmail(me.email) === newEmail) {
    throw new ApiError("CONFLICT", "That is already your email");
  }
  const taken = await c.env.DB.prepare(
    "SELECT 1 FROM users WHERE email = ? AND id <> ? AND deleted_at IS NULL",
  ).bind(newEmail, userId).first();
  if (taken) throw new ApiError("CONFLICT", "Email already in use");

  const code = sixDigitCode();
  const codeHash = await sha256Hex(code);
  await c.env.KV.put(`ec:${userId}`, JSON.stringify({ codeHash, newEmail }), {
    expirationTtl: EMAIL_CODE_TTL_SECONDS,
  });

  const e2e = c.env.E2E_TEST_MODE === "1";
  if (e2e) {
    try { await sendEmailChangeCode(c.env, { to: newEmail, code }); } catch { /* no local EMAIL binding in e2e */ }
    return c.json({ sent: true, devCode: code }, 202);
  }
  await sendEmailChangeCode(c.env, { to: newEmail, code });
  return c.json({ sent: true }, 202);
});

accountRoutes.post("/users/me/email/verify", validate("json", verifyBody), async (c) => {
  const userId = c.var.userId;
  const { code } = c.req.valid("json");

  const raw = await c.env.KV.get(`ec:${userId}`);
  if (!raw) throw new ApiError("GONE", "No pending email change");
  const { codeHash, newEmail } = JSON.parse(raw) as { codeHash: string; newEmail: string };
  if ((await sha256Hex(code)) !== codeHash) throw new ApiError("VALIDATION_FAILED", "Incorrect code");

  const taken = await c.env.DB.prepare(
    "SELECT 1 FROM users WHERE email = ? AND id <> ? AND deleted_at IS NULL",
  ).bind(newEmail, userId).first();
  if (taken) throw new ApiError("CONFLICT", "Email already in use");

  const now = nowMs();
  await c.env.DB.prepare("UPDATE users SET email = ?, email_verified = 1, updated_at = ? WHERE id = ?")
    .bind(newEmail, now, userId).run();
  await c.env.KV.delete(`ec:${userId}`);

  const u = await c.env.DB.prepare("SELECT id, email, display_name, plan FROM users WHERE id = ?")
    .bind(userId).first<{ id: string; email: string | null; display_name: string | null; plan: string }>();
  return c.json({ user: { id: u!.id, email: u!.email, displayName: u!.display_name, plan: u!.plan } });
});
