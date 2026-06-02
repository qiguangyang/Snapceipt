/**
 * AU bookkeeping CSV for /export. Pure: the route queries D1 + resolves receipt
 * keys + signs links, then hands rows here. Columns (spec §4.3):
 *   date,merchant,category,amount_incl_gst,gst,deductible_pct,payment_method,note,receipt_url
 * Amounts are dollars (cents/100, 2dp). receipt_url is a 7-day signed
 * /export/dl/:token link to the receipt image key (NOT the authed /images route);
 * empty when the txn has no image. Row order is the caller's input order
 * (route passes txn_date DESC, id ASC) — deterministic.
 */

/** The transaction columns this builder reads (snake_case D1 shape). */
export interface CsvTxnRow {
  id: string;
  txn_date: string;
  merchant: string;
  cat_key: string;
  amount_cents: number;
  gst_cents: number | null;
  deductible_pct: number | null;
  payment_method: string | null;
  note: string | null;
}

export interface BuildCsvInput {
  profileName: string;
  periodLabel: string;
  rows: CsvTxnRow[];
  /** transactionId -> receipt image R2 key (first/primary image). */
  receiptKeyByTxnId: Map<string, string>;
  /** e.g. "https://api.snapceipt.cc" — the public origin for the dl link. */
  baseUrl: string;
  /** Signs a 7-day download token for an R2 key (route passes the JWT signer). */
  signDownload: (r2Key: string) => Promise<string>;
}

const COLUMNS =
  "date,merchant,category,amount_incl_gst,gst,deductible_pct,payment_method,note,receipt_url";

/** RFC 4180 field escaping: wrap in quotes + double internal quotes when the
 *  field contains a comma, quote, CR or LF. */
function csvField(value: string): string {
  if (/[",\r\n]/.test(value)) {
    return `"${value.replace(/"/g, '""')}"`;
  }
  return value;
}

/** Cents -> fixed 2-dp dollar string, sign preserved (-3300 -> "-33.00"). */
function dollars(cents: number): string {
  return (cents / 100).toFixed(2);
}

export async function buildExportCsv(input: BuildCsvInput): Promise<string> {
  const lines: string[] = [];
  // Line 0: a doc comment (prefixed with '#') naming the profile + period.
  lines.push(`# Snapceipt export — ${csvField(input.profileName)} — ${csvField(input.periodLabel)}`);
  // Line 1: the column header.
  lines.push(COLUMNS);

  for (const r of input.rows) {
    let receiptUrl = "";
    const key = input.receiptKeyByTxnId.get(r.id);
    if (key) {
      const token = await input.signDownload(key);
      receiptUrl = `${input.baseUrl}/export/dl/${token}`;
    }
    const fields = [
      r.txn_date,
      csvField(r.merchant),
      r.cat_key,
      dollars(r.amount_cents),
      r.gst_cents == null ? "" : dollars(r.gst_cents),
      r.deductible_pct == null ? "" : String(r.deductible_pct),
      r.payment_method == null ? "" : csvField(r.payment_method),
      r.note == null ? "" : csvField(r.note),
      receiptUrl, // already a URL; tokens are URL-safe so no escaping needed
    ];
    lines.push(fields.join(","));
  }

  return lines.join("\n");
}
