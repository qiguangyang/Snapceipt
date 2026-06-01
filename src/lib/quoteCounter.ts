/**
 * Per-user quote-number counter (spec §4.3). The send route calls this exactly
 * once per quote — on the FIRST send, when quotes.number is still NULL. A re-send
 * keeps the existing number, so this is never called again for that quote.
 *
 * The assignment is atomic: a single INSERT … ON CONFLICT … RETURNING bumps and
 * returns next_seq in one statement, so two concurrent sends for the same user
 * get distinct sequences (1, 2) and never collide. quotes.ux_quote_number
 * (UNIQUE(user_id, number) WHERE number IS NOT NULL AND deleted_at IS NULL) is
 * the backstop.
 */

/** Format a 1-based sequence as SN-#### (4-digit zero-padded). */
export function formatQuoteNumber(seq: number): string {
  return `SN-${String(seq).padStart(4, "0")}`;
}

/**
 * Atomically allocate the next per-user sequence and return the formatted
 * SN-#### number. First call for a user returns SN-0001, then SN-0002, …
 */
export async function assignQuoteNumber(db: D1Database, userId: string): Promise<string> {
  const row = await db
    .prepare(
      `INSERT INTO quote_counters (user_id, next_seq) VALUES (?, 1)
       ON CONFLICT(user_id) DO UPDATE SET next_seq = next_seq + 1
       RETURNING next_seq`,
    )
    .bind(userId)
    .first<{ next_seq: number }>();
  const seq = row?.next_seq ?? 1;
  return formatQuoteNumber(seq);
}
