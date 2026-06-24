// src/lib/ocr.ts

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
