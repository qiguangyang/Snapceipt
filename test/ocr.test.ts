import { describe, expect, it } from "vitest";
import { STUB_OCR_TEXT, workersAiOcr } from "../src/lib/ocr";
import type { Env } from "../src/env";

const buf = new TextEncoder().encode("not-a-real-image").buffer as ArrayBuffer;

describe("workersAiOcr — gating", () => {
  it("returns the deterministic stub when E2E_EMAIL_MODE === '1'", async () => {
    const env = { E2E_EMAIL_MODE: "1", AI: { run: async () => ({ description: "REAL" }) } } as unknown as Env;
    expect(await workersAiOcr(env, buf, "image/jpeg")).toBe(STUB_OCR_TEXT);
  });

  it("returns the stub when the AI binding is absent", async () => {
    const env = { AI: undefined } as unknown as Env;
    expect(await workersAiOcr(env, buf, "image/jpeg")).toBe(STUB_OCR_TEXT);
  });

  it("calls Workers AI and returns its text when not gated", async () => {
    const env = { AI: { run: async () => ({ description: " ACME 33.00 " }) } } as unknown as Env;
    expect(await workersAiOcr(env, buf, "image/jpeg")).toBe("ACME 33.00");
  });
});
