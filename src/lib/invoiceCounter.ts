/**
 * Per-PROFILE invoice-number counter (spec §5). The issue route calls this exactly
 * once per invoice — on the FIRST issue, when invoices.number is still NULL. A
 * re-issue keeps the existing number, so this is never called again for that invoice.
 *
 * The assignment is atomic: a single INSERT … ON CONFLICT … RETURNING bumps and
 * returns next_seq in one statement, so two concurrent issues for the same profile
 * get distinct sequences (1, 2) and never collide. invoices.ux_invoice_number
 * (UNIQUE(profile_id, number) WHERE number IS NOT NULL AND deleted_at IS NULL) is
 * the backstop.
 */

/** Format a 1-based sequence as INV-#### (4-digit zero-padded). */
export function formatInvoiceNumber(seq: number): string {
  return `INV-${String(seq).padStart(4, "0")}`;
}

/**
 * Atomically allocate the next per-profile sequence and return the formatted
 * INV-#### number. First call for a profile returns INV-0001, then INV-0002, …
 */
export async function assignInvoiceNumber(db: D1Database, profileId: string): Promise<string> {
  const row = await db
    .prepare(
      `INSERT INTO invoice_counters (profile_id, next_seq) VALUES (?, 1)
       ON CONFLICT(profile_id) DO UPDATE SET next_seq = next_seq + 1
       RETURNING next_seq`,
    )
    .bind(profileId)
    .first<{ next_seq: number }>();
  const seq = row?.next_seq ?? 1;
  return formatInvoiceNumber(seq);
}
