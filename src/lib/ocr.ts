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

// LLaVA needs no Meta-Llama license acceptance (unlike llama-3.2-vision, which 5016s until
// the account submits "agree"). Input/output shape ({image, prompt} -> {description}) matches.
const OCR_MODEL = "@cf/llava-hf/llava-1.5-7b-hf";
const OCR_PROMPT = "Transcribe ALL text from this receipt image exactly. Output only the raw text.";

/**
 * OCR a receipt image via Workers AI. Gated: when E2E_EMAIL_MODE === "1" or the
 * AI binding is absent, returns STUB_OCR_TEXT so the suite stays hermetic.
 */
export async function workersAiOcr(env: Env, bytes: ArrayBuffer, _contentType: string): Promise<string> {
  if (env.E2E_EMAIL_MODE === "1" || !env.AI) return STUB_OCR_TEXT;
  const image = Array.from(new Uint8Array(bytes));
  // max_tokens bumped so a dense receipt's full text isn't truncated (LLaVA defaults low).
  const result = (await env.AI.run(OCR_MODEL, { image, prompt: OCR_PROMPT, max_tokens: 1800 })) as {
    description?: string;
    response?: string;
  };
  return (result.description ?? result.response ?? "").trim();
}
