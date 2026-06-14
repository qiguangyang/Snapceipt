import { describe, it, expect } from "vitest";
import { buildBasCsv, type BasCsvTxnRow } from "./csvBas";
import { basEngine } from "./basEngine";

const rows: BasCsvTxnRow[] = [
  { id: "a", txn_date: "2026-04-10", merchant: "Client Co", cat_key: "income", amount_cents: 1100000, gst_cents: 100000, deductible_pct: null, payment_method: "card", note: null, gst_free: 0, capital: 0, gst_source: "derived" },
  { id: "b", txn_date: "2026-04-12", merchant: "Officeworks", cat_key: "office", amount_cents: -110000, gst_cents: 10000, deductible_pct: 100, payment_method: "card", note: null, gst_free: 0, capital: 0, gst_source: "printed" },
  { id: "c", txn_date: "2026-05-01", merchant: "Dell", cat_key: "software", amount_cents: -220000, gst_cents: 20000, deductible_pct: 100, payment_method: "card", note: null, gst_free: 0, capital: 1, gst_source: "derived" },
  { id: "d", txn_date: "2026-05-03", merchant: "Woolworths", cat_key: "groceries", amount_cents: -33000, gst_cents: null, deductible_pct: 100, payment_method: "card", note: "=cmd|' /c calc'", gst_free: 1, capital: 0, gst_source: null },
];

const bas = basEngine(
  rows.map((r) => ({ amountCents: r.amount_cents, gstFree: r.gst_free === 1, capital: r.capital === 1 })),
  { gstRegistered: true, manual: { paygInstalmentCents: 0 } },
);

async function build(rowsArg: BasCsvTxnRow[] = rows, basArg = bas) {
  return buildBasCsv({
    profileName: "Acme Pty Ltd",
    periodLabel: "2026-04-01 to 2026-06-30",
    rows: rowsArg,
    bas: basArg,
    receiptKeyByTxnId: new Map(),
    baseUrl: "https://api.test",
    signDownload: async () => "TOKEN",
  });
}

describe("buildBasCsv", () => {
  it("adds gst_free/capital/gst_source/bas_labels columns to the header", async () => {
    const csv = await build();
    const header = csv.split("\n")[1];
    expect(header).toContain("gst_free");
    expect(header).toContain("capital");
    expect(header).toContain("gst_source");
    expect(header).toContain("bas_labels");
  });

  it("labels a taxable sale G1, a non-capital purchase G11, a capital purchase G10, a GST-free purchase G11;G14", async () => {
    const csv = await build();
    const lines = csv.split("\n");
    expect(lines.find((l) => l.startsWith("2026-04-10"))).toContain("G1");
    expect(lines.find((l) => l.startsWith("2026-04-12"))).toContain("G11");
    expect(lines.find((l) => l.startsWith("2026-05-01"))).toContain("G10");
    // GST-free non-capital purchase hits both G11 and G14 (semicolon multi-value).
    expect(lines.find((l) => l.startsWith("2026-05-03"))).toContain("G11;G14");
  });

  it("splits the capital label at exactly $1,000 (G11) vs $1,000.01 (G10) — shared threshold", async () => {
    const boundaryRows: BasCsvTxnRow[] = [
      { id: "x", txn_date: "2026-06-01", merchant: "AtBoundary", cat_key: "tools", amount_cents: -100000, gst_cents: null, deductible_pct: 100, payment_method: "card", note: null, gst_free: 0, capital: 1, gst_source: null },
      { id: "y", txn_date: "2026-06-02", merchant: "OverBoundary", cat_key: "tools", amount_cents: -100001, gst_cents: null, deductible_pct: 100, payment_method: "card", note: null, gst_free: 0, capital: 1, gst_source: null },
    ];
    const boundaryBas = basEngine(
      boundaryRows.map((r) => ({ amountCents: r.amount_cents, gstFree: r.gst_free === 1, capital: r.capital === 1 })),
      { gstRegistered: true, manual: { paygInstalmentCents: 0 } },
    );
    const csv = await build(boundaryRows, boundaryBas);
    const lines = csv.split("\n");
    const atRow = lines.find((l) => l.startsWith("2026-06-01"))!;
    const overRow = lines.find((l) => l.startsWith("2026-06-02"))!;
    // Exactly $1,000 stays in G11 (NOT G10); $1,000.01 lands in G10.
    expect(atRow).toContain("G11");
    expect(atRow).not.toContain("G10");
    expect(overRow).toContain("G10");
  });

  it("foots the totals row to the worksheet labels (reconciles to the PDF)", async () => {
    const csv = await build();
    const footer = csv.split("\n").find((l) => l.startsWith("# TOTALS"));
    expect(footer).toBeDefined();
    expect(footer).toContain("G1=11000.00");
    expect(footer).toContain("1A=1000.00");
    expect(footer).toContain("1B=300.00");
  });

  it("neutralizes a formula-injection note (CWE-1236)", async () => {
    const csv = await build();
    // The malicious note starts with '=' and must be prefixed with a single quote.
    expect(csv).toContain("'=cmd|' /c calc'");
  });
});
