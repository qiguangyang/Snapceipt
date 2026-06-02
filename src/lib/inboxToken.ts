// src/lib/inboxToken.ts
// Per-profile inbox alias token: an opaque random secret stored in
// profile_inbox_tokens (NOT a signed JWT). The address selects the profile.

const INBOX_DOMAIN = "in.snapceipt.cc";
const PREFIX = "r.";

export interface InboxOwner {
  userId: string;
  profileId: string;
}

/** 16 random bytes -> 32 lowercase hex chars. Unguessable; collision-free in practice. */
export function generateInboxToken(): string {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
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

/** Overwrite the profile's token with a fresh one (old token stops resolving). */
export async function rotateInboxToken(
  db: D1Database,
  userId: string,
  profileId: string,
  now: number,
): Promise<string> {
  const token = generateInboxToken();
  await db
    .prepare(
      `INSERT INTO profile_inbox_tokens (token, user_id, profile_id, created_at)
       VALUES (?, ?, ?, ?)
       ON CONFLICT(profile_id) DO UPDATE SET token = excluded.token, created_at = excluded.created_at`,
    )
    .bind(token, userId, profileId, now)
    .run();
  return token;
}
