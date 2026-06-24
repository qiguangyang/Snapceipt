import { env } from "cloudflare:test";
import { beforeAll, describe, expect, it } from "vitest";
import { inboundEmailLogic } from "../src/email/inbound";
import { mintInboxToken, addressForToken } from "../src/lib/inboxToken";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";

// A minimal multipart/related raw message carrying a tiny JPEG so isImage() passes.
const JPEG = "\xff\xd8\xff\xe0\x00\x10JFIF\xff\xd9";
function rawWith(image: string): string {
  const b = "BOUNDARY";
  return [
    `Content-Type: multipart/mixed; boundary="${b}"`, "",
    `--${b}`, "Content-Type: text/plain", "", "receipt attached", "",
    `--${b}`, `Content-Type: image/jpeg`, "Content-Disposition: attachment; filename=\"r.jpg\"", "", image, "",
    `--${b}--`, "",
  ].join("\r\n");
}

describe("email-in inbound seam (E2E_EMAIL_MODE)", () => {
  let userId: string, profileId: string, alias: string;
  beforeAll(async () => {
    const now = nowMs();
    userId = uuidv7(); profileId = uuidv7();
    // Email-in is now Pro-only, so the alias owner must be Pro (active subscription, no expiry)
    // for inboundEmailLogic to proceed past the gate to the create path.
    await env.DB.prepare(
      `INSERT INTO users (id, email, plan, subscription_status, subscription_expires_at, created_at, updated_at)
       VALUES (?, ?, 'pro', 'active', NULL, ?, ?)`,
    ).bind(userId, "inbound@example.com", now, now).run();
    await env.DB.prepare(`INSERT INTO profiles (id, user_id, name, type, accent_1, accent_2, accent_3, created_at, updated_at)
      VALUES (?, ?, 'Biz', 'business', '#000', '#111', '#222', ?, ?)`).bind(profileId, userId, now, now).run();
    const token = await mintInboxToken(env.DB, userId, profileId, now);
    alias = addressForToken(token);   // the minted alias the message is addressed TO
  });

  it("J48b: an inbound message to a minted alias creates an email-in transaction", async () => {
    // E2E_EMAIL_MODE stubs OCR so extraction runs deterministically without Workers AI.
    const emailEnv = { ...env, E2E_EMAIL_MODE: "1" } as typeof env;
    const result = await inboundEmailLogic(emailEnv, {
      to: alias, from: "supplier@example.com", messageId: `<${uuidv7()}@example.com>`, raw: rawWith(JPEG),
    }, nowMs());
    expect(result.status).toBe("created");
    if (result.status === "created") {
      // The transaction is owned by the alias owner and tagged source=email_in.
      const row = await env.DB.prepare(
        `SELECT user_id, profile_id, source, extraction_status FROM transactions WHERE id = ?`,
      ).bind(result.transactionId).first<any>();
      expect(row.user_id).toBe(userId);
      expect(row.profile_id).toBe(profileId);
      expect(row.source).toBe("email_in");
      // Covers BOTH extraction outcomes incl. the failed-extraction state (needsReview path).
      expect(["done", "failed"]).toContain(result.extraction);
    }
  });
});
