// test/deepseek.test.ts
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  runGeminiVisionExtraction,
  reconcileGst,
  normalizeCurrency,
  inclusiveTaxCap,
  trimReceiptTail,
  detectMerchant,
  detectDate,
  parseStructuredLineItems,
} from "../src/lib/deepseek";

/** Real-world noisy PDF receipt: ABN starting with 88, mostly GST-free, a payment block (the
 * brand only appears here), a printed "includes GST $1.64", and a BWS wine/beer promo tail. */
const WOOLIES = [
  "1129 Macquarie Ryde PH: 02 9308 7337",
  "TAX INVOICE - ABN 88 000 014 675",
  "Kiwifruit Gold New Zealand",
  "0.977 kg NET @ $10.90/kg 10.65",
  "^SunRice Calrose Rice Med Grain 10kg 19.00",
  "31 SUBTOTAL $176.98",
  "TOTAL $176.98",
  "-------------------------",
  "WOOLWORTHS 1129",
  "NORTH RYDE NSW",
  "CARD:.............2834 B",
  "X-2834 $176.98",
  "#Taxable Items",
  "TOTAL includes GST $1.64",
  "You saved $107.00",
  "Cookware Credits",
  "BUY ANY 2 WINES FOR $22 & SAVE $18",
  "Cape Campbell Sauvignon Blanc",
].join("\n");

describe("GST reconcile + tail trim + merchant detect", () => {
  it("prefers the printed GST over an impossible model value (ABN $88)", () => {
    expect(reconcileGst(88, 176.98, WOOLIES, "AUD")).toBe(1.64);
  });
  it("clamps an impossible GST to total/11 when none is printed (AUD)", () => {
    expect(reconcileGst(88, 176.98, "TOTAL 176.98", "AUD")).toBe(16.09);
  });
  it("keeps a valid GST at or under total/11 (AUD)", () => {
    expect(reconcileGst(1.64, 176.98, WOOLIES, "AUD")).toBe(1.64);
  });
  it("honors a printed GST slightly above total/11 (surcharge/rounding), not just at/under it", () => {
    // Yakitori case: GST 11.55 on a 115.50 subtotal, total 117.23 includes a 1.73 surcharge,
    // so 11.55 > total/11 (10.66) yet is the merchant's printed GST — must be kept, not clamped.
    const txt = "Subtotal (9) 115.50\nGST 11.55\nVISA 1.73\nTotal 117.23";
    expect(reconcileGst(11.55, 117.23, txt, "AUD")).toBe(11.55);
  });
  it("still rejects a gross GST mis-read above ~12% of total and clamps to total/11 (AUD)", () => {
    // A "GST" line carrying an absurd figure (e.g. an ABN/payment grab) is not trusted; with
    // no valid printed line the model value clamps to total/11.
    expect(reconcileGst(11.55, 117.23, "GST 88.00\nTotal 117.23", "AUD")).toBe(10.66); // 117.23/11
  });
  it("clamps an impossible GST to the NZ inclusive cap (15% = total×3/23) when none is printed", () => {
    expect(reconcileGst(88, 115, "TOTAL 115.00", "NZD")).toBe(15); // 115 × 3/23 = 15.00
  });
  it("does NOT clamp US/Canada sales tax (exclusive + variable) — the model value stands", () => {
    expect(reconcileGst(8.88, 100, "", "USD")).toBe(8.88); // 8.875% NYC tax, no inclusive cap
    expect(reconcileGst(13, 100, "", "CAD")).toBe(13);     // 13% Ontario HST, no inclusive cap
  });
  it("normalizeCurrency accepts AUD/NZD/USD/CAD, defaults unknown/empty to AUD", () => {
    for (const c of ["AUD", "NZD", "USD", "CAD"]) expect(normalizeCurrency(c)).toBe(c);
    expect(normalizeCurrency("nzd")).toBe("NZD");      // case-insensitive
    expect(normalizeCurrency("GBP")).toBe("AUD");      // unsupported → default
    expect(normalizeCurrency(null)).toBe("AUD");
    expect(normalizeCurrency("")).toBe("AUD");
  });
  it("inclusiveTaxCap: AU total/11, NZ total×3/23, US/CA null (exclusive)", () => {
    expect(inclusiveTaxCap("AUD", 176.98)).toBe(16.09);
    expect(inclusiveTaxCap("NZD", 115)).toBe(15);
    expect(inclusiveTaxCap("USD", 100)).toBeNull();
    expect(inclusiveTaxCap("CAD", 100)).toBeNull();
  });
  it("trims the payment block + promo tail but keeps items + totals", () => {
    const t = trimReceiptTail(WOOLIES);
    expect(t).toContain("Kiwifruit Gold");
    expect(t).toContain("TOTAL $176.98");
    // payment block + promo gone → can't leak as items
    expect(t).not.toContain("WOOLWORTHS 1129");
    expect(t).not.toContain("CARD:");
    expect(t).not.toContain("X-2834");
    expect(t).not.toContain("Cape Campbell");
  });
  it("detects the real merchant brand from anywhere in the receipt", () => {
    expect(detectMerchant(WOOLIES)).toBe("Woolworths");
    expect(detectMerchant("Just a corner store\nTOTAL 5.00")).toBeNull();
  });

  it("reads the transaction date (printed next to a time), not promo expiry dates", () => {
    const txt = [
      "TOTAL  $58.40",
      "21/03/26 17:21  002573",
      "TERM ID:  W1129088",
      "POS 088 TRANS 2573 17:22 21/03/2026",
      "BEER OFFERS EXPIRE: 09.06.2026",
      "WINE OFFERS EXPIRE: 30.06.2026",
    ].join("\n");
    expect(detectDate(txt)).toBe("2026-03-21");
  });

  it("returns null when no date is present (keeps the model's date)", () => {
    expect(detectDate("Woolworths\nTOTAL $58.40")).toBeNull();
  });
});

/** The full Woolworths item block: product-name lines + weight/qty detail lines + simple
 * lines + a discount, summing to the $176.98 total. */
const FULL_WOOLIES = [
  "Kiwifruit Gold New Zealand",
  "0.977 kg NET @ $10.90/kg 10.65",
  "Banana Cavendish",
  "2.062 kg NET @ $4.50/kg 9.28",
  "Capsicum Red",
  "0.232 kg NET @ $7.90/kg 1.83",
  "Broccoli",
  "0.562 kg NET @ $4.50/kg 2.53",
  "Mandarin Amorette Seedless",
  "0.917 kg NET @ $3.90/kg 3.58",
  "^Amaysim Sim Starter Kit 40 AUD 15.00",
  "^Amaysim Sim Starter Kit 40 AUD 15.00",
  "^Amaysim Sim Starter Kit 40 AUD 15.00",
  "^SunRice Calrose Rice Med Grain 10kg 19.00",
  "^#Huggies UD Nappy Pnts Girls Sz5 26pk 13.00",
  "#Viva Select-A-Size Paper Towel 3pk 5.00",
  "Bega Cheese Stringers 8pk 160g",
  "Qty 2 @ $7.50 each 15.00",
  "Macro FR Chicken Split Lemon & Garlic 12.01",
  "Sweet Corn 500g P/P 4.50",
  "Farmers Union Greek Pouch Peach 130g",
  "Qty 2 @ $2.50 each 5.00",
  "Farmers Union Yoghurt Pouch Pfruit 130g 2.50",
  "Farmers Union Greek Yogurt Mango 130g",
  "Qty 2 @ $2.50 each 5.00",
  "FARMERS UNION OFFER -4.00",
  "Pear The Odd Bunch 1kg PP 2.80",
  "Persimmon",
  "Qty 5 @ $2.00 each 10.00",
  "Broccolini Bunch",
  "Qty 2 @ $2.30 each 4.60",
  "Carrot 1kg P/P 1.70",
  "Berry Raspberry 125g P/P",
  "Qty 2 @ $4.00 each 8.00",
  "^Promotional Price",
  "31 SUBTOTAL $176.98",
  "TOTAL $176.98",
].join("\n");

describe("parseStructuredLineItems", () => {
  const items = parseStructuredLineItems(FULL_WOOLIES);
  const byName = (sub: string) => items.find((i) => i.name.includes(sub));

  it("pairs a product name with its weight detail line + line total (not the /kg price)", () => {
    expect(byName("Kiwifruit Gold New Zealand")).toEqual({
      name: "Kiwifruit Gold New Zealand",
      price: 10.65,
    });
    expect(byName("Banana Cavendish")?.price).toBe(9.28);
  });

  it("pairs qty detail lines and takes the line total", () => {
    expect(byName("Bega Cheese Stringers")?.price).toBe(15.0);
    expect(byName("Persimmon")?.price).toBe(10.0);
  });

  it("does not read a size token as a price (130g/125g)", () => {
    expect(byName("Pfruit 130g")?.price).toBe(2.5);
    expect(byName("Berry Raspberry 125g")?.price).toBe(8.0);
  });

  it("items sum to the receipt total", () => {
    const sum = items.reduce((a, i) => a + i.price, 0);
    expect(Math.abs(sum - 176.98)).toBeLessThan(0.02);
  });
});

/** Coles Local layout: per-unit ("2 @ $2.75 EACH") and per-kg ("1.261 kg NET @ $4.50/kg")
 * sub-lines have NO trailing line-total (their amount is a unit price); a bare "EFT $34.87"
 * payment line. All three must be skipped, leaving the 6 real items that sum to 34.87. */
const COLES_LOCAL = [
  "Coles Supermarkets Australia Pty Ltd",
  "Tax Invoice ABN: 45 004 189 708",
  "coles local",
  "Store: 852 - CS CHATSWOOD",
  "Store Manager: Jay",
  "Phone: 02 8216 4000",
  "Served By: Assisted Checkout",
  "Register: 111 Receipt: 9098",
  "Date: 20/06/2026 Time: 19:04",
  "Description $",
  "* RAW C PURE NATURAL C 1LITRE 5.50",
  "2 @ $2.75 EACH",
  "% ORAL B DENTAL FLOSS 50METRE 4.00",
  "BLUEBERRIES 125GRAM 5.50",
  "BLACKBERRIES 125GRAM 5.00",
  "KRAFT BLUEY CHEESE S 200GRAM 9.20",
  "BANANAS PERKG 5.67",
  "1.261 kg NET @ $4.50/kg",
  "Total for 7 items: $34.87",
  "EFT $34.87",
  "GST INCLUDED IN TOTAL $0.36",
].join("\n");

describe("parseStructuredLineItems — Coles Local (skips unit/per-kg sub-lines + EFT)", () => {
  const items = parseStructuredLineItems(COLES_LOCAL);

  it("returns EXACTLY the 6 real items with their prices, summing to 34.87", () => {
    expect(items).toEqual([
      { name: "RAW C PURE NATURAL C 1LITRE", price: 5.5 },
      { name: "% ORAL B DENTAL FLOSS 50METRE", price: 4.0 },
      { name: "BLUEBERRIES 125GRAM", price: 5.5 },
      { name: "BLACKBERRIES 125GRAM", price: 5.0 },
      { name: "KRAFT BLUEY CHEESE S 200GRAM", price: 9.2 },
      { name: "BANANAS PERKG", price: 5.67 },
    ]);
    const sum = items.reduce((a, i) => a + i.price, 0);
    expect(Math.abs(sum - 34.87)).toBeLessThan(0.005);
  });

  it("drops the per-unit sub-line, the per-kg sub-line, and the EFT payment line", () => {
    const names = items.map((i) => i.name);
    expect(names.some((n) => /2 @ \$2\.75 EACH/i.test(n))).toBe(false);
    expect(names.some((n) => /\/kg/i.test(n))).toBe(false);
    expect(names.some((n) => /\beft\b/i.test(n))).toBe(false);
    // the 2.75 unit price and the 4.50 per-kg price never become item prices
    expect(items.some((i) => i.price === 2.75)).toBe(false);
    expect(items.some((i) => i.price === 4.5)).toBe(false);
  });
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("runGeminiVisionExtraction", () => {
  const img = new TextEncoder().encode("fake-image-bytes").buffer as ArrayBuffer;
  const geminiBody = (obj: unknown) => ({
    ok: true, status: 200,
    json: async () => ({ candidates: [{ content: { parts: [{ text: JSON.stringify(obj) }] } }] }),
  });

  it("sends an inline_data image part and parses the response", async () => {
    const calls: any[] = [];
    const orig = globalThis.fetch;
    globalThis.fetch = (async (url: string, init: any) => {
      calls.push({ url, init });
      return geminiBody({ merchant: "Woolworths", date: "2026-05-30", currencyCode: "AUD",
        total: 176.98, gst: 1.64, category: "groceries", deductible: 0,
        lineItems: [{ name: "Banana", price: 9.28 }], confidence: 0.95 });
    }) as any;
    try {
      const env = { GEMINI_API_KEY: "k" } as any;
      const out = await runGeminiVisionExtraction(env, img, "image/png", "2026-06-24");
      expect(out.receipt.merchant).toBe("Woolworths");
      expect(out.receipt.total).toBe(176.98);
      expect(out.meta.usedLlm).toBe(true);
      const body = JSON.parse(calls[0].init.body);
      const parts = body.contents[0].parts;
      expect(parts.some((p: any) => p.inline_data?.mime_type === "image/png" && p.inline_data?.data)).toBe(true);
      expect(String(calls[0].url)).toContain("gemini-3.1-flash-lite:generateContent");
      expect(calls[0].init.headers["x-goog-api-key"]).toBe("k");
    } finally { globalThis.fetch = orig; }
  });

  it("throws on a non-OK response", async () => {
    const orig = globalThis.fetch;
    globalThis.fetch = (async () => ({ ok: false, status: 400, text: async () => "bad" })) as any;
    try {
      const env = { GEMINI_API_KEY: "k" } as any;
      await expect(runGeminiVisionExtraction(env, img, "image/png", "2026-06-24")).rejects.toThrow();
    } finally { globalThis.fetch = orig; }
  });

  it("backfills a missing date to defaultDate", async () => {
    const orig = globalThis.fetch;
    globalThis.fetch = (async () => geminiBody({ merchant: "X", date: null, currencyCode: "AUD",
      total: 10, gst: null, category: "office", deductible: 100, lineItems: [], confidence: 0.5 })) as any;
    try {
      const env = { GEMINI_API_KEY: "k" } as any;
      const out = await runGeminiVisionExtraction(env, img, "image/jpeg", "2026-06-24");
      expect(out.receipt.date).toBe("2026-06-24");
    } finally { globalThis.fetch = orig; }
  });
});
