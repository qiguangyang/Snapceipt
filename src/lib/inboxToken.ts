// src/lib/inboxToken.ts
// Per-profile inbox alias token: an opaque random secret stored in
// profile_inbox_tokens (NOT a signed JWT). The address selects the profile.

const INBOX_DOMAIN = "in.snapceipt.cc";
const PREFIX = "r.";

export interface InboxOwner {
  userId: string;
  profileId: string;
}

/** Lowercase RFC 4648 base32 alphabet (a-z, 2-7) — denser than hex and email-local-part safe
 * (no 0/1/8/9, so no 0/o or 1/l ambiguity). */
const BASE32 = "abcdefghijklmnopqrstuvwxyz234567";

/** 8 random bytes (64 bits) -> 13 lowercase base32 chars. Short but unguessable for a Pro-gated +
 * rate-limited email alias: a brute-force needs one SENT email per guess, and 2^64 is infeasible.
 * Existing 32-hex aliases keep resolving (DB lookup, no format check) — only NEW tokens are short. */
export function generateInboxToken(): string {
  const bytes = new Uint8Array(8);
  crypto.getRandomValues(bytes);
  let bits = 0;
  let value = 0;
  let out = "";
  for (const b of bytes) {
    value = (value << 8) | b;
    bits += 8;
    while (bits >= 5) {
      out += BASE32[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += BASE32[(value << (5 - bits)) & 31]; // final 4 bits → 1 char (13 total)
  return out;
}

/** Format the public alias for a token. The client treats the result as opaque. */
export function addressForToken(token: string): string {
  return `${PREFIX}${token}@${INBOX_DOMAIN}`;
}

/** Parse the token out of a recipient address; null when it is not an r.<token> alias. */
export function tokenFromRecipient(to: string): string | null {
  const local = (to.trim().toLowerCase().split("@")[0] ?? "");
  if (!local.startsWith(PREFIX)) return null;
  const token = local.slice(PREFIX.length);
  return token.length > 0 ? token : null;
}

export async function resolveInboxToken(db: D1Database, token: string): Promise<InboxOwner | null> {
  const row = await db
    .prepare("SELECT user_id, profile_id FROM profile_inbox_tokens WHERE token = ?")
    .bind(token)
    .first<{ user_id: string; profile_id: string }>();
  return row ? { userId: row.user_id, profileId: row.profile_id } : null;
}

/** Return the profile's existing token, minting one if absent. Never rotates. */
export async function mintInboxToken(
  db: D1Database,
  userId: string,
  profileId: string,
  now: number,
): Promise<string> {
  const existing = await db
    .prepare("SELECT token FROM profile_inbox_tokens WHERE profile_id = ?")
    .bind(profileId)
    .first<{ token: string }>();
  if (existing) return existing.token;

  const token = generateInboxToken();
  await db
    .prepare(
      `INSERT INTO profile_inbox_tokens (token, user_id, profile_id, created_at)
       VALUES (?, ?, ?, ?) ON CONFLICT(profile_id) DO NOTHING`,
    )
    .bind(token, userId, profileId, now)
    .run();
  // Re-read: a concurrent insert may have won the ON CONFLICT no-op.
  const row = await db
    .prepare("SELECT token FROM profile_inbox_tokens WHERE profile_id = ?")
    .bind(profileId)
    .first<{ token: string }>();
  return row!.token;
}
