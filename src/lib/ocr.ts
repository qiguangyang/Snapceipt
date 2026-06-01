// src/lib/ocr.ts
import type { Env } from "../env";

/**
 * Deterministic OCR text for the stub seam. Crafted so heuristicExtract picks a
 * merchant + a 33.00 total (the email-in extraction stub mirrors /extract).
 */
export const STUB_OCR_TEXT = [
  "ACME HARDWARE PTY LTD",
  "123 Trade St, Sydney NSW",
  "Drill bits        18.00",
  "Safety gloves     12.00",
  "GST                3.00",
  "TOTAL             33.00",
].join("\n");

const OCR_MODEL = "@cf/meta/llama-3.2-11b-vision-instruct";
const OCR_PROMPT = "Transcribe ALL text from this receipt image exactly. Output only the raw text.";

/**
 * OCR a receipt image via Workers AI. Gated: when E2E_EMAIL_MODE === "1" or the
 * AI binding is absent, returns STUB_OCR_TEXT so the suite stays hermetic.
 */
export async function workersAiOcr(env: Env, bytes: ArrayBuffer, _contentType: string): Promise<string> {
  if (env.E2E_EMAIL_MODE === "1" || !env.AI) return STUB_OCR_TEXT;
  const image = Array.from(new Uint8Array(bytes));
  const result = (await env.AI.run(OCR_MODEL, { image, prompt: OCR_PROMPT })) as {
    description?: string;
    response?: string;
  };
  return (result.description ?? result.response ?? "").trim();
}
