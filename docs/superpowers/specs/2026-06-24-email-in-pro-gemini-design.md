# Email-in receipts → Pro-only, server Gemini extraction — design

**Date:** 2026-06-24
**Status:** Approved (brainstorming) — pending spec review → implementation plan.

## Goal

Make **email-in receipts** a reliable, **Pro-only** feature backed by **Google Gemini** vision extraction on the server. A Pro user forwards/emails a receipt photo to their per-profile alias (`r.<token>@in.snapceipt.cc`); the worker sends the image directly to `gemini-3.1-flash-lite`, which returns the structured receipt in one call. Free users do not get email-in — their inbound mail is bounced and the alias endpoints + the in-app Email-in screen are Pro-gated.

This replaces the failed OCR-model journey (Workers AI `llama-3.2-vision` was license-gated; `llava-1.5-7b` produced garbage; DeepSeek's API is text-only — all dead ends). Gemini was verified live against the real Woolworths receipt: it returned merchant **Woolworths**, date **2026-05-30**, total **$176.98**, GST **$1.64**, and all **23 line items** correctly (weight/qty lines resolved to product names, the −$4.00 discount captured), ~1.7k tokens, ~4.7s.

## Decisions (from brainstorming)

1. **Email-in is Pro-only.** No free tier, no on-device path for email-in.
2. **Pro inbound email → server Gemini** (`gemini-3.1-flash-lite`) vision extraction → a `done` transaction.
3. **Free inbound email → bounce** ("Email-in is a Pro feature — upgrade in the app to use it."). No storage, no AI spend.
4. **Pro-gate the alias endpoints** (`GET /profiles/:id/inbox`, `POST /profiles/:id/inbox/rotate`) and the **iOS Email-in screen** — free users see an upgrade prompt and cannot mint an alias.
5. **No non-AI on-device extraction** anywhere (deleted earlier; not reintroduced). On-device auto-extraction = Apple FM only, and that path is unchanged by this work.
6. **In-app camera scan is untouched** — the shipped FM/cloud (DeepSeek) routing stays exactly as-is.
7. **Pro = `src/lib/plan.ts`** check (validates `users.plan === "pro"` + subscription status/expiry, server-side so the client can't bypass payment). `plan.ts` currently exports `requireProPlan(c: Context)` (route/context-based). The routes use it directly; `inboundEmailLogic` (not a Hono route) needs a `userId`-based variant — extract a small `isProUser(db, userId): Promise<boolean>` from `requireProPlan`'s existing query (`users.plan` + subscription_status/expires_at) and have `requireProPlan` call it, so both paths share one source of truth.

## Behavior matrix (email-in only)

| Sender's plan | Inbound email result |
|---|---|
| **Pro** | Gemini vision extraction → `created` transaction (`done`); on Gemini failure → `failed` ("Needs review", image kept) |
| **Free** (incl. downgraded ex-Pro with an old alias) | **Bounced** via `setReject` (reason `pro_only`); no image stored, no AI |

The existing inbound guards remain: DMARC-fail reject, Message-ID dedup, per-alias hourly rate limit, image-presence + size cap, and the monthly smart-scan cap gate (Pro budget; over-cap → image saved + `failed` needs-review, no AI spend).

## Architecture

### New — `src/lib/gemini.ts`
`runGeminiVisionExtraction(env, imageBytes: ArrayBuffer, contentType: string, defaultDate: string): Promise<DeepseekResult>`
- POST `https://generativelanguage.googleapis.com/v1beta/models/${env.GEMINI_MODEL ?? "gemini-3.1-flash-lite"}:generateContent`, header `x-goog-api-key: ${env.GEMINI_API_KEY}`, with the same ~15s abort budget as `callDeepseek`.
- Body: `{ contents: [{ parts: [ {text: <prompt>}, {inline_data: {mime_type: contentType, data: <chunked base64 of imageBytes>}} ] }], generationConfig: { responseMimeType: "application/json", temperature: 0, maxOutputTokens: 1500 } }`.
- Prompt = the existing `SYSTEM_PROMPT` intent (AU receipts; the 9 categories; GST rule; line-item exclusion rules) adapted to "extract from this receipt image", so Gemini returns the full `deepseekReceiptSchema` shape (merchant, date, currencyCode, total, gst, category, deductible, lineItems, confidence).
- Read `candidates[0].content.parts[0].text` → `tryParseReceipt` (reuse) → `finalize({ ocrText: "", source: "email_in", defaultDate }, parsed)`. No OCR text, so the deterministic text guards (`printedGst`/`parseStructuredLineItems`) no-op — Gemini's structured output is the source of truth; `finalize` still clamps total/GST and backfills the date.
- Throw on fetch/timeout/non-OK/unparseable (so the caller marks the txn `failed` — never a silent zeros receipt). Chunked base64 helper (0x8000-byte chunks) — never spread a large `Uint8Array`.

### Changed — `src/email/inbound.ts`
- After `resolveInboxToken`, apply the **`isProUser(env.DB, owner.userId)`** check (the userId-based helper from decision 7). If NOT Pro → return `{ status: "rejected", reason: "pro_only" }` (no dedup/image/AI work). If Pro → proceed.
- Replace the extraction call with `runGeminiVisionExtraction(env, buf, contentType, defaultDate)` (drop `workersAiOcr` and the DeepSeek-vision `runDeepseekVisionExtraction`). Keep the stub gate (`E2E_EXTRACT_MODE` / no `GEMINI_API_KEY` → the existing deterministic stub so tests stay hermetic), the cap gate, `chargeSlot`/`incrementUsage`, the sanity gate (empty result → `failed`), and `logInbound`.
- `InboundResult` rejected reason union gains `"pro_only"`.

### Changed — `src/index.ts` (`email()` handler)
- Map `reason === "pro_only"` → `message.setReject("Email-in is a Pro feature — upgrade in the app to use it.")`.

### Changed — `src/routes/inbox.ts`
- Pro-gate both routes: after `assertOwnedProfile`, call `requireProPlan(c)` (it throws a 402-style `ApiError` for non-Pro) so free clients can show an upgrade prompt and cannot mint/rotate an alias.

### Changed — iOS `EmailInView` (+ `EmailInViewModel`)
- Pro-gate the screen. Free users (the alias endpoint now 402s) see an **upgrade prompt** (reuse the app's existing paywall/Pro-gating pattern, e.g. as used by the BAS card / quotes) instead of the address card + inbox list. Pro users get the existing screen unchanged.

### Config — `env.ts` + secret
- Add `GEMINI_API_KEY: string` (and optional `GEMINI_MODEL`) to the `Env` type. Set `GEMINI_API_KEY` as a prod secret (`wrangler secret put GEMINI_API_KEY`).

## Data flow

Inbound email → `email()` (DMARC check) → `inboundEmailLogic`: resolve alias → **Pro check** → (free → `rejected:pro_only` → `setReject` bounce) / (Pro → dedup → rate-limit → image → R2 → cap-gate → **Gemini** → sanity-gate → `writeReceiptRows` → `logInbound created`).

## Error handling / fallbacks

- Free sender → bounce (clear upgrade message).
- Gemini timeout/error/empty → caught → `failed` transaction ("Needs review", image kept) — Pro user never loses the receipt.
- Sanity gate: a vision result with `total <= 0 && lineItems.length === 0` → `failed` (not a misleading zeros "created").
- Over monthly cap (Pro) → image saved + `failed` needs-review, no AI spend.

## Removed / cleanup

- The DeepSeek-vision email-in path (`runDeepseekVisionExtraction` + its inbound wiring, commit `2477cd01`) — revert/replace.
- `workersAiOcr` / `src/lib/ocr.ts`'s `OCR_MODEL` (the LLaVA swap) is now fully unused by email-in. Remove `workersAiOcr` + its `OCR_MODEL`/`OCR_PROMPT` if nothing else references them; keep `STUB_OCR_TEXT` only if the stub still uses it.
- Redeploy prod to replace the currently-broken DeepSeek-vision build.

## Testing

- **Gemini extraction** (`runGeminiVisionExtraction`) — mocked `fetch`: assert the request carries an `inline_data` image part + the prompt, and a valid response is parsed + `finalize`d into an `ExtractedReceipt`; throw-on-failure + throw-on-unparseable.
- **`inboundEmailLogic`** — Pro owner → Gemini (mocked) → `created`; free owner → `rejected:pro_only` (no image stored, no AI). Sanity gate (empty → `failed`). Stub gate keeps existing inbound tests hermetic.
- **Inbox routes** — Pro owner → alias minted/rotated; free owner → 402 upgrade error.
- **Live Gemini** — already verified against the real Woolworths receipt (perfect extraction).
- **iOS** — `EmailInView` Pro-gate: free → upgrade prompt; Pro → address + inbox.
- Full backend `vitest` suite stays green.

## Out of scope

- Changing the in-app camera scan (FM/cloud routing) — untouched.
- Reintroducing any non-AI on-device extraction.
- Using Gemini for the in-app cloud scan path (the app's cloud scan stays on DeepSeek text) — a possible future unification, not now.
- Document AI (considered, heavier setup; Gemini chosen instead).

## Related memory

[[email-in-receipts]] (the OCR-model journey + Email Routing setup), [[on-device-foundation-models-extraction]] (the in-app FM path, unchanged here).
