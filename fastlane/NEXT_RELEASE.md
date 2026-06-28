# Next App Store release — staged metadata & checklist

This file tracks App Store metadata that is **staged for the next version**. The
`fastlane release` lane runs `deliver` with `skip_metadata: false` and
`metadata_path: "./metadata"`, so **everything in `fastlane/metadata/` is
uploaded automatically with the next binary** — there is no separate "push the
keywords" step. You just need these files to be correct before you run the lane.

## Why these were queued (not already live)

App Store **keywords** and **subtitle** can only change when you submit a **new
app version**. They were prepared while **v1.0.0 was `WAITING_FOR_REVIEW`**, so
they ride the next version (1.x). `promotional_text` is the exception — it is
**live-editable any time** in App Store Connect without a new build.

## Staged for the next version

- **`metadata/en-AU/keywords.txt`** — the 100-char keyword field was rewritten
  to stop wasting characters on words already in the app **name**
  (`Snapceipt — Receipts & GST`) and **subtitle** (`Expenses, GST & BAS, sorted`),
  which Apple indexes *together* with the keyword field. Those reclaimed chars
  now hold un-covered AU / feature terms. Current value (98/100):

  ```
  scanner,tracker,ATO,deduction,mileage,logbook,sole,trader,small,business,invoice,quote,bookkeeping
  ```

  Editing rules: **≤100 chars, no spaces** (single words let Apple build the
  most search-term combinations — e.g. `sole`+`trader` → "sole trader",
  `scanner`+`receipts` → "receipt scanner"), and **never repeat a word already
  in the name/subtitle** (`snapceipt, receipts, gst, expenses, bas, sorted`).

- **`metadata/en-AU/promotional_text.txt`** — refreshed to mention quotes &
  invoices (151/170 chars). Live-editable; can be pushed now via ASC or
  `deliver` without a new build.

## Pre-release checklist (run at the next `fastlane release`)

- [ ] **Update `metadata/en-AU/release_notes.txt`** — it still contains the
      v1.0.0 *"First public release…"* copy. Replace it with the new version's
      **What's New** before submitting, or the update will show "First public
      release". (Candidate items: the Share Extension shipped on TestFlight
      1.1.0 — "share receipts straight from other apps" — plus anything else
      since 1.0.0.)
- [ ] Confirm `keywords.txt` is the intended set above — it ships automatically.
- [ ] (Optional) Consider a **subtitle** tune-up. It's prime ASO real estate;
      the current `Expenses, GST & BAS, sorted` is all AU-tax. Only changeable
      with a new version.
- [ ] Version/build are handled by the lane (build = latest TestFlight + 1).

## Related lifecycle reminder (separate from the next version)

- After Apple **approves v1.0.0**, run `npx wrangler secret delete REVIEW_DEMO_EMAIL`
  to close the review-2FA bypass on the demo account. See the App Store
  submission notes.
