import { CAPITAL_THRESHOLD_CENTS, type BasResult } from "./basEngine";

/**
 * BAS backing CSV (spec §4.5b). The period txn list with the existing export
 * columns PLUS gst_free (0/1), capital (0/1), gst_source, and a bas_labels
 * column (semicolon-delimited multi-value: a txn can hit several labels, e.g. a
 * capital GST-free purchase = "G10;G14"). A "# TOTALS" footer row foots to the
 * worksheet labels (G1/1A/1B …) so the CSV reconciles to the PDF — per-txn
 * gst_cents is reference only; 1A/1B are the worksheet round(aggregate/11)
 * figures. Keeps the formula-injection guard + 7-day signed receipt_url links.
 * CAPITAL_THRESHOLD_CENTS is imported from basEngine (single source of truth) so
 * the per-row G10/G11 split cannot drift from the engine's G10 aggregate.
 */

export interface BasCsvTxnRow {
  id: string;
  txn_date: string;
  merchant: string;
  cat_key: string;
  amount_cents: number;
  gst_cents: number | null;
  deductible_pct: number | null;
  payment_method: string | null;
  note: string | null;
  gst_free: number; // 0/1
  capital: number; // 0/1
  gst_source: string | null;
}

export interface BuildBasCsvInput {
  profileName: string;
  periodLabel: string;
  rows: BasCsvTxnRow[];
  bas: BasResult;
  receiptKeyByTxnId: Map<string, string>;
  baseUrl: string;
  signDownload: (r2Key: string) => Promise<string>;
}

const COLUMNS =
  "date,merchant,category,amount_incl_gst,gst,deductible_pct,payment_method,note,gst_free,capital,gst_source,bas_labels,receipt_url";

/** Neutralize CSV / formula injection (CWE-1236) — identical guard to csvExport.ts. */
function neutralizeFormula(value: string): string {
  return /^[=+\-@\t\r]/.test(value) ? `'${value}` : value;
}

function csvField(value: string): string {
  const safe = neutralizeFormula(value);
  if (/[",\r\n]/.test(safe)) {
    return `"${safe.replace(/"/g, '""')}"`;
  }
  return safe;
}

function dollars(cents: number): string {
  return (cents / 100).toFixed(2);
}

/** The §4.5b multi-value label set for one txn (semicolon-delimited). */
function basLabels(r: BasCsvTxnRow): string {
  const labels: string[] = [];
  if (r.amount_cents > 0) {
    labels.push("G1");
    if (r.gst_free === 1) labels.push("G3");
  } else if (r.amount_cents < 0) {
    const mag = -r.amount_cents;
    labels.push(r.capital === 1 && mag > CAPITAL_THRESHOLD_CENTS ? "G10" : "G11");
    if (r.gst_free === 1) labels.push("G14");
  }
  return labels.join(";");
}

export async function buildBasCsv(input: BuildBasCsvInput): Promise<string> {
  const lines: string[] = [];
  lines.push(`# Snapceipt BAS export — ${csvField(input.profileName)} — ${csvField(input.periodLabel)}`);
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
      String(r.gst_free),
      String(r.capital),
      r.gst_source == null ? "" : r.gst_source,
      basLabels(r),
      receiptUrl,
    ];
    lines.push(fields.join(","));
  }

  // Totals footer — foots to the worksheet labels (NOT to Σ gst_cents). The 1A/1B
  // figures are the worksheet round(aggregate/11) values that match the PDF.
  const b = input.bas;
  lines.push(
    `# TOTALS (worksheet method, round(aggregate/11)): ` +
      `G1=${dollars(b.g1)};G10=${dollars(b.g10)};G11=${dollars(b.g11)};G14=${dollars(b.g14)};` +
      `1A=${dollars(b.oneA)};1B=${dollars(b.oneB)};net9=${dollars(b.netGstCents)};` +
      `5A=${dollars(b.paygCents)};total=${dollars(b.totalPayableCents)}`,
  );

  return lines.join("\n");
}
