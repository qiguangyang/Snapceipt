// test/deepseek.test.ts
import { afterEach, describe, expect, it, vi } from "vitest";
import { runDeepseekExtraction } from "../src/lib/deepseek";

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

  it("strips ``` fences and extracts the first {…} on attempt 3 before falling back", async () => {
    const fenced = "```json\n" + VALID_CONTENT + "\n```";
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(chatResponse("garbage"))
      .mockResolvedValueOnce(chatResponse("still garbage"))
      .mockResolvedValueOnce(chatResponse(fenced));
    vi.stubGlobal("fetch", fetchMock);

    const out = await runDeepseekExtraction(ENV, { ocrText: OCR, source: "scan", defaultDate: "2026-05-30" });

    expect(fetchMock).toHaveBeenCalledTimes(3);
    expect(out.receipt.merchant).toBe("The Grounds");
    expect(out.receipt.needsReview).toBe(false);
  });

  it("falls back to the heuristic with needsReview when always invalid (<=3 attempts)", async () => {
    const fetchMock = vi.fn().mockResolvedValue(chatResponse("never valid json"));
    vi.stubGlobal("fetch", fetchMock);

    const out = await runDeepseekExtraction(ENV, { ocrText: OCR, source: "scan", defaultDate: "2026-05-30" });

    expect(fetchMock).toHaveBeenCalledTimes(3);
    expect(out.receipt.needsReview).toBe(true);
    expect(out.receipt.category).toBe("office"); // heuristic fallback default
    expect(out.receipt.deductible).toBe(100);
    expect(out.receipt.confidence).toBeLessThan(0.8);
    expect(out.receipt.total).toBe(33.0); // largest amount from OCR
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
