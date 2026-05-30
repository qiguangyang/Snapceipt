// test/extract-schema.test.ts
import { describe, expect, it } from "vitest";
import {
  extractRequestSchema,
  deepseekReceiptSchema,
  CATEGORY_KEYS,
} from "../src/schemas/extract";

describe("extractRequestSchema", () => {
  it("requires ocrText + source and applies server defaults to the optional fields", () => {
    const parsed = extractRequestSchema.parse({ ocrText: "X", source: "scan" });
    expect(parsed.defaultCurrency).toBe("AUD");
    expect(parsed.locale).toBe("en-AU");
    expect(parsed.capturedAt).toBeUndefined();
    expect(parsed.requestId).toBeUndefined();
  });

  it("rejects an empty ocrText", () => {
    expect(extractRequestSchema.safeParse({ ocrText: "", source: "scan" }).success).toBe(false);
  });

  it("rejects an unknown source", () => {
    expect(
      extractRequestSchema.safeParse({ ocrText: "X", source: "fax" }).success,
    ).toBe(false);
  });

  it("accepts email_in as a source and a provided capturedAt + requestId", () => {
    const parsed = extractRequestSchema.parse({
      ocrText: "X",
      source: "email_in",
      capturedAt: "2026-05-28",
      requestId: "abc",
    });
    expect(parsed.source).toBe("email_in");
    expect(parsed.capturedAt).toBe("2026-05-28");
    expect(parsed.requestId).toBe("abc");
  });

  it("rejects a malformed capturedAt", () => {
    expect(
      extractRequestSchema.safeParse({ ocrText: "X", source: "scan", capturedAt: "28-05-2026" })
        .success,
    ).toBe(false);
  });
});

describe("CATEGORY_KEYS", () => {
  it("is exactly the 9 keys (no 'custom')", () => {
    expect(CATEGORY_KEYS).toEqual([
      "meals",
      "groceries",
      "fuel",
      "software",
      "office",
      "home",
      "health",
      "travel",
      "income",
    ]);
  });
});

describe("deepseekReceiptSchema", () => {
  const valid = {
    merchant: "The Grounds",
    date: "2026-05-28",
    currencyCode: "AUD",
    total: 42.5,
    gst: 3.86,
    category: "meals",
    deductible: 50,
    lineItems: [{ name: "Flat White", price: 9 }],
    confidence: 0.98,
  };

  it("accepts a well-formed DeepSeek receipt", () => {
    expect(deepseekReceiptSchema.safeParse(valid).success).toBe(true);
  });

  it("rejects an out-of-set category", () => {
    expect(deepseekReceiptSchema.safeParse({ ...valid, category: "custom" }).success).toBe(false);
  });

  it("accepts a null gst (model omitted it) and a null deductible", () => {
    const r = deepseekReceiptSchema.parse({ ...valid, gst: null, deductible: null });
    expect(r.gst).toBeNull();
    expect(r.deductible).toBeNull();
  });

  it("rejects a negative total", () => {
    expect(deepseekReceiptSchema.safeParse({ ...valid, total: -1 }).success).toBe(false);
  });

  it("rejects a deductible outside 0..100", () => {
    expect(deepseekReceiptSchema.safeParse({ ...valid, deductible: 150 }).success).toBe(false);
  });

  it("rejects a confidence outside 0..1", () => {
    expect(deepseekReceiptSchema.safeParse({ ...valid, confidence: 2 }).success).toBe(false);
  });

  it("defaults confidence to undefined-tolerant (optional) when absent", () => {
    const { confidence, ...noConf } = valid;
    const parsed = deepseekReceiptSchema.parse(noConf);
    expect(parsed.confidence).toBeUndefined();
  });
});
