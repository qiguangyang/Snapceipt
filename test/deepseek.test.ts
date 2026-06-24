// test/deepseek.test.ts
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  runDeepseekExtraction,
  runDeepseekVisionExtraction,
  reconcileGst,
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
    expect(reconcileGst(88, 176.98, WOOLIES)).toBe(1.64);
  });
  it("clamps an impossible GST to total/11 when none is printed", () => {
    expect(reconcileGst(88, 176.98, "TOTAL 176.98")).toBe(16.09);
  });
  it("keeps a valid GST at or under total/11", () => {
    expect(reconcileGst(1.64, 176.98, WOOLIES)).toBe(1.64);
  });
  it("honors a printed GST slightly above total/11 (surcharge/rounding), not just at/under it", () => {
    // Yakitori case: GST 11.55 on a 115.50 subtotal, total 117.23 includes a 1.73 surcharge,
    // so 11.55 > total/11 (10.66) yet is the merchant's printed GST — must be kept, not clamped.
    const txt = "Subtotal (9) 115.50\nGST 11.55\nVISA 1.73\nTotal 117.23";
    expect(reconcileGst(11.55, 117.23, txt)).toBe(11.55);
  });
  it("still rejects a gross GST mis-read above ~12% of total and clamps to total/11", () => {
    // A "GST" line carrying an absurd figure (e.g. an ABN/payment grab) is not trusted; with
    // no valid printed line the model value clamps to total/11.
    expect(reconcileGst(11.55, 117.23, "GST 88.00\nTotal 117.23")).toBe(10.66); // 117.23/11 rounded
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

const ENV = {
  DEEPSEEK_API_KEY: "sk-test",
  DEEPSEEK_MODEL: "deepseek-chat",
} as unknown as import("../src/env").Env;

const OCR = ["THE GROUNDS", "28/05/2026", "Flat White 9.00", "Big Brekkie 24.00", "TOTAL 33.00"].join(
  "\n",
);

/** A DeepSeek chat-completions response wrapping the given content string. */
function chatResponse(content: string): Response {
  return new Response(
    JSON.stringify({ choices: [{ message: { content } }] }),
    { status: 200, headers: { "content-type": "application/json" } },
  );
}

const VALID_CONTENT = JSON.stringify({
  merchant: "The Grounds",
  date: "2026-05-28",
  currencyCode: "AUD",
  total: 33.0,
  gst: 3.0,
  category: "meals",
  deductible: 50,
  lineItems: [
    { name: "Flat White", price: 9.0 },
    { name: "Big Brekkie", price: 24.0 },
  ],
  confidence: 0.95,
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("runDeepseekExtraction()", () => {
  it("returns the parsed receipt in ONE attempt for valid JSON", async () => {
    const fetchMock = vi.fn().mockResolvedValue(chatResponse(VALID_CONTENT));
    vi.stubGlobal("fetch", fetchMock);

    const out = await runDeepseekExtraction(ENV, { ocrText: OCR, source: "scan", defaultDate: "2026-05-30" });

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(out.meta.attempts).toBe(1);
    expect(out.meta.model).toBe("deepseek-chat");
    expect(out.meta.stub).toBe(false);
    expect(out.receipt.merchant).toBe("The Grounds");
    expect(out.receipt.category).toBe("meals");
    expect(out.receipt.needsReview).toBe(false); // arithmetic consistent + high model conf
  });

  it("accepts a valid receipt with date:null (backfills the date) instead of discarding it", async () => {
    // Regression: the model returns date:null (date in the trimmed footer). Previously the
    // strict isoDate rejected the whole — otherwise perfect — extraction, forcing a retry and
    // then the much worse heuristic fallback. Now it is accepted and the date backfills.
    const withNullDate = JSON.stringify({
      merchant: "Japan City", date: null, currencyCode: "AUD", total: 48.68, gst: 4.42,
      category: "meals", deductible: 50,
      lineItems: [
        { name: "Udon Fisherman", price: 19.9 },
        { name: "Wagyu Don", price: 19.9 },
        { name: "Edamame", price: 4.5 },
        { name: "Dango", price: 3.9 },
      ],
      confidence: 0.85,
    });
    const fetchMock = vi.fn().mockResolvedValue(chatResponse(withNullDate));
    vi.stubGlobal("fetch", fetchMock);

    const out = await runDeepseekExtraction(ENV, {
      ocrText: "Japan City\nno date on this receipt\nTOTAL 48.68",
      source: "scan",
      defaultDate: "2026-06-20",
    });

    expect(fetchMock).toHaveBeenCalledTimes(1);          // accepted on attempt 1, no retry
    expect(out.meta.usedLlm).toBe(true);                 // the AI result, NOT the heuristic fallback
    expect(out.receipt.date).toBe("2026-06-20");         // backfilled to capturedAt/today
    expect(out.receipt.merchant).toBe("Japan City");
    expect(out.receipt.lineItems.map((l) => l.name)).toContain("Udon Fisherman");
    expect(out.receipt.lineItems.map((l) => l.name)).not.toContain("ABN"); // no heuristic junk
  });

  it("sends the row-paired layoutText to the model and parses line items from it", async () => {
    // Two-column case: raw OCR order separates names from amounts, so the model must read the
    // row-paired layoutText. Here the model still returns junk; layoutText carries clean rows
    // summing to the total, so the deterministic parser wins.
    const junk = JSON.stringify({
      merchant: "Japan City Chatswood",
      date: "2026-06-20",
      currencyCode: "AUD",
      total: 48.68,
      gst: 4.42,
      category: "meals",
      deductible: 0,
      lineItems: [
        { name: "ABN: 85 629 947", price: 85.0 },
        { name: "Shop 601 Westfield", price: 601.0 },
        { name: "NSW", price: 2067.0 },
      ],
      confidence: 0.6,
    });
    const fetchMock = vi.fn().mockResolvedValue(chatResponse(junk));
    vi.stubGlobal("fetch", fetchMock);

    const rawOcr = ["Japan City Chatswood", "ABN: 85 629 947 780", "(Udon) Fisherman", "19.90"].join("\n");
    const layout = [
      "(Udon) Fisherman  19.90  1  19.90",
      "( DON ) Wagyu  19.90  1  19.90",
      "Edamame  4.50  1  4.50",
      "Dango  3.90  1  3.90",
      "Credit Card Surch  0.48  1  0.48",
      "TOTAL  $48.68",
    ].join("\n");

    const out = await runDeepseekExtraction(ENV, {
      ocrText: rawOcr,
      layoutText: layout,
      source: "scan",
      defaultDate: "2026-06-20",
    });

    // The model is given the LAYOUT text (rows pair name↔price), not the scrambled raw order.
    const sentBody = JSON.parse(fetchMock.mock.calls[0][1].body);
    expect(sentBody.messages.at(-1).content).toContain("19.90  1  19.90");
    expect(sentBody.messages.at(-1).content).not.toContain("ABN: 85 629 947");
    // The deterministic parser (layoutText) reconciled to $48.68 and replaced the junk.
    const names = out.receipt.lineItems.map((li) => li.name);
    expect(names).not.toContain("NSW");
    expect(out.receipt.lineItems.some((li) => li.name.includes("Fisherman"))).toBe(true);
    expect(out.receipt.lineItems.some((li) => li.price === 4.5)).toBe(true);
  });

  it("retries once on invalid-then-valid (2 attempts)", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(chatResponse("not json at all"))
      .mockResolvedValueOnce(chatResponse(VALID_CONTENT));
    vi.stubGlobal("fetch", fetchMock);

    const out = await runDeepseekExtraction(ENV, { ocrText: OCR, source: "scan", defaultDate: "2026-05-30" });

    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(out.meta.attempts).toBe(2);
    expect(out.receipt.category).toBe("meals");
  });

  it("strips ``` fences and extracts the first {…} on the retry (attempt 2) before falling back", async () => {
    const fenced = "```json\n" + VALID_CONTENT + "\n```";
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(chatResponse("garbage"))
      .mockResolvedValueOnce(chatResponse(fenced));
    vi.stubGlobal("fetch", fetchMock);

    const out = await runDeepseekExtraction(ENV, { ocrText: OCR, source: "scan", defaultDate: "2026-05-30" });

    // MAX_ATTEMPTS=2: one retry. Attempt 1 invalid, attempt 2 valid (fenced) → success.
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(out.receipt.merchant).toBe("The Grounds");
    expect(out.receipt.needsReview).toBe(false);
  });

  it("falls back to the heuristic with needsReview when always invalid (<=2 attempts)", async () => {
    const fetchMock = vi.fn().mockResolvedValue(chatResponse("never valid json"));
    vi.stubGlobal("fetch", fetchMock);

    const out = await runDeepseekExtraction(ENV, { ocrText: OCR, source: "scan", defaultDate: "2026-05-30" });

    // MAX_ATTEMPTS=2: both attempts invalid → heuristic fallback.
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(out.receipt.needsReview).toBe(true);
    expect(out.receipt.category).toBe("office"); // heuristic fallback default
    expect(out.receipt.deductible).toBe(100);
    expect(out.receipt.confidence).toBeLessThan(0.8);
    expect(out.receipt.total).toBe(33.0); // largest amount from OCR
  });

  it("sets usedLlm:true when the LLM produced a parseable answer", async () => {
    const fetchMock = vi.fn().mockResolvedValue(chatResponse(VALID_CONTENT));
    vi.stubGlobal("fetch", fetchMock);

    const out = await runDeepseekExtraction(ENV, { ocrText: OCR, source: "scan", defaultDate: "2026-05-30" });

    expect(out.meta.usedLlm).toBe(true);
  });

  it("sets usedLlm:false when all attempts exhausted and fell back to heuristic", async () => {
    // All attempts fail with non-parseable content — simulates DeepSeek outage.
    const fetchMock = vi.fn().mockResolvedValue(chatResponse("not json"));
    vi.stubGlobal("fetch", fetchMock);

    const out = await runDeepseekExtraction(ENV, { ocrText: OCR, source: "scan", defaultDate: "2026-05-30" });

    expect(out.meta.usedLlm).toBe(false);
    expect(out.receipt.needsReview).toBe(true);
  });

  it("sets usedLlm:false when fetch always rejects (network/timeout outage)", async () => {
    const fetchMock = vi.fn().mockRejectedValue(new Error("network error"));
    vi.stubGlobal("fetch", fetchMock);

    const out = await runDeepseekExtraction(ENV, { ocrText: OCR, source: "scan", defaultDate: "2026-05-30" });

    expect(out.meta.usedLlm).toBe(false);
  });

  it("infers AU GST = round(total/11) when the model returns gst:null and total>0", async () => {
    const noGst = JSON.stringify({
      merchant: "Cafe", date: "2026-05-28", currencyCode: "AUD",
      total: 11.0, gst: null, category: "meals", deductible: 50,
      lineItems: [{ name: "Coffee", price: 11.0 }], confidence: 0.9,
    });
    const fetchMock = vi.fn().mockResolvedValue(chatResponse(noGst));
    vi.stubGlobal("fetch", fetchMock);

    const out = await runDeepseekExtraction(ENV, { ocrText: "Cafe\nCoffee 11.00", source: "scan", defaultDate: "2026-05-30" });
    expect(out.receipt.gst).toBe(1); // 11/11
  });

  it("keeps gst null only when total is 0", async () => {
    const zero = JSON.stringify({
      merchant: "Refund", date: "2026-05-28", currencyCode: "AUD",
      total: 0, gst: null, category: "income", deductible: null,
      lineItems: [], confidence: 0.9,
    });
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(chatResponse(zero)));
    const out = await runDeepseekExtraction(ENV, { ocrText: "Refund", source: "scan", defaultDate: "2026-05-30" });
    expect(out.receipt.gst).toBeNull();
    expect(out.receipt.total).toBe(0);
  });

  it("coerces deductible to an integer (model 50.0 -> integer-valued 50, never a float)", async () => {
    const floaty = JSON.stringify({
      merchant: "Cafe", date: "2026-05-28", currencyCode: "AUD",
      total: 11.0, gst: 1.0, category: "meals", deductible: 50.0,
      lineItems: [{ name: "Coffee", price: 11.0 }], confidence: 0.9,
    });
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(chatResponse(floaty)));
    const out = await runDeepseekExtraction(ENV, { ocrText: "Cafe\nCoffee 11.00", source: "scan", defaultDate: "2026-05-30" });
    expect(out.receipt.deductible).toBe(50);
    expect(Number.isInteger(out.receipt.deductible)).toBe(true);
  });

  it("lowers confidence + flips needsReview when line items don't sum to total", async () => {
    const mismatch = JSON.stringify({
      merchant: "Shop", date: "2026-05-28", currencyCode: "AUD",
      total: 100.0, gst: 9.09, category: "office", deductible: 100,
      lineItems: [{ name: "Thing", price: 5.0 }], confidence: 0.6,
    });
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(chatResponse(mismatch)));
    const out = await runDeepseekExtraction(ENV, { ocrText: "Shop\nThing 5.00\nTOTAL 100.00", source: "scan", defaultDate: "2026-05-30" });
    // 0.55*0.6 + 0.25*ocrQuality + 0.20*0.5 -> below 0.8
    expect(out.receipt.confidence).toBeLessThan(0.8);
    expect(out.receipt.needsReview).toBe(true);
  });

  it("aborts and falls back when the request times out (20s budget)", async () => {
    // Simulate fetch rejecting with an AbortError on every attempt.
    const abortErr = Object.assign(new Error("aborted"), { name: "AbortError" });
    const fetchMock = vi.fn().mockRejectedValue(abortErr);
    vi.stubGlobal("fetch", fetchMock);

    const out = await runDeepseekExtraction(ENV, { ocrText: OCR, source: "scan", defaultDate: "2026-05-30" });
    expect(out.receipt.needsReview).toBe(true);
    expect(out.receipt.category).toBe("office");
  });
});

describe("runDeepseekVisionExtraction()", () => {
  // A tiny fake JPEG payload (binary bytes) to be base64-encoded into the data URL.
  const imageBytes = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46])
    .buffer as ArrayBuffer;

  it("sends an image_url data URL in the user content array and parses+finalizes the result", async () => {
    const fetchMock = vi.fn().mockResolvedValue(chatResponse(VALID_CONTENT));
    vi.stubGlobal("fetch", fetchMock);

    const out = await runDeepseekVisionExtraction(ENV, imageBytes, "image/jpeg", "2026-06-24");

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const sentBody = JSON.parse(fetchMock.mock.calls[0][1].body);
    // user message content is the OpenAI-compatible multimodal array
    const userMsg = sentBody.messages.find((m: any) => m.role === "user");
    expect(Array.isArray(userMsg.content)).toBe(true);
    const imagePart = userMsg.content.find((p: any) => p.type === "image_url");
    expect(imagePart).toBeTruthy();
    expect(imagePart.image_url.url).toMatch(/^data:image\/jpeg;base64,/);
    const textPart = userMsg.content.find((p: any) => p.type === "text");
    expect(textPart.text).toContain("json");
    expect(sentBody.model).toBe("deepseek-chat"); // ENV.DEEPSEEK_MODEL

    // parsed + finalized into an ExtractedReceipt
    expect(out.meta.usedLlm).toBe(true);
    expect(out.meta.stub).toBe(false);
    expect(out.receipt.merchant).toBe("The Grounds");
    expect(out.receipt.category).toBe("meals");
    expect(out.receipt.total).toBe(33.0);
  });

  it("backfills the date to defaultDate (no OCR text for detectDate)", async () => {
    const withNullDate = JSON.stringify({
      merchant: "Cafe", date: null, currencyCode: "AUD", total: 11.0, gst: 1.0,
      category: "meals", deductible: 50, lineItems: [{ name: "Coffee", price: 11.0 }], confidence: 0.9,
    });
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(chatResponse(withNullDate)));
    const out = await runDeepseekVisionExtraction(ENV, imageBytes, "image/jpeg", "2026-06-24");
    expect(out.receipt.date).toBe("2026-06-24");
  });

  it("uses the default model when DEEPSEEK_MODEL is unset", async () => {
    const fetchMock = vi.fn().mockResolvedValue(chatResponse(VALID_CONTENT));
    vi.stubGlobal("fetch", fetchMock);
    const envNoModel = { DEEPSEEK_API_KEY: "sk-test" } as unknown as import("../src/env").Env;
    await runDeepseekVisionExtraction(envNoModel, imageBytes, "image/png", "2026-06-24");
    const sentBody = JSON.parse(fetchMock.mock.calls[0][1].body);
    expect(sentBody.model).toBe("deepseek-v4-flash");
  });

  it("THROWS when fetch fails (network/timeout) so the caller marks it failed", async () => {
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("network error")));
    await expect(runDeepseekVisionExtraction(ENV, imageBytes, "image/jpeg", "2026-06-24")).rejects.toThrow();
  });

  it("THROWS when the response is never parseable (after the corrective retry)", async () => {
    const fetchMock = vi.fn().mockResolvedValue(chatResponse("not json at all"));
    vi.stubGlobal("fetch", fetchMock);
    await expect(runDeepseekVisionExtraction(ENV, imageBytes, "image/jpeg", "2026-06-24")).rejects.toThrow();
    expect(fetchMock).toHaveBeenCalledTimes(2); // one corrective retry
  });
});
