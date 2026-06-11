# Beta-Hardening — Deferred Findings

Findings surfaced by the polish audit (Plan A) that are **out of guardrail**
(spec §8) — logged here, never built in this program.

Format per entry:
- **[area]** short description — _why deferred_ (v1.1 deferral / flow restructuring / new feature / needs product decision) — source PNG.

---

- **[01-onboarding-auth]** area01-02 — selecting the "Business" profile type in the first-profile form does not switch the default accent off personal terracotta (Continue + selected swatch stay orange unless the user manually taps the teal swatch) — _needs product decision: the accent picker is deliberately independent of profile type; auto-defaulting accent on type change is a behavior/UX-default change, not visual polish_ — `artifacts/tour/a01-audit/01-onboarding-auth/onboarding-profile-business.png`.
- **[01-onboarding-auth]** area01-05 — `PermissionPrimingView(.camera)` (and notifications) priming is unreachable in the live first-run flow, so the `permission-priming-camera` tour shot is never produced (RootView gates onboarding on `profileRows.isEmpty`, so inserting the first profile re-renders straight into the shell before OnboardingView can advance to its `.camera` step) — _flow restructuring: making priming reachable requires re-ordering the first-run flow_ — missing `permission-priming-camera.png` (see `ScreenshotTourUITests.swift` test_area01_onboardingAuth comment + `RootView.swift:32`).
- **[04-capture]** area04-06 — the Review screen's Date row shows the raw ISO string (`2026-06-11`) rather than a friendly date (`28 May 2026`); the field is an editable free-text `TextField` bound to `draft.date` ("YYYY-MM-DD"). Making it friendly while keeping it editable, or swapping it for a `DatePicker`, changes the input control's editing behavior — not pure visual polish — _needs product decision: review-field editing-control change, out of the visual/micro-UX guardrail_ — `artifacts/tour/a04-audit/04-capture/capture-review.png`.
- **[04-capture]** area04-07 — ScanStep renders a blank white card (no receipt content) and a flat scan line because the stub has no captured image; the prototype shows the faux ReceiptPaper behind a glowing accent line + glow frame. The empty card is inherent to the tour stub (real capture supplies the receipt image), and the documented Area-4 divergence list states there are "no documented divergences beyond stub-only stages" — _v1.1 deferral: stub-only stage artifact; the scan-stage polish (glow frame + faux-receipt placeholder) depends on real capture and is not representative of production_ — `artifacts/tour/a04-audit/04-capture/capture-scanning.png`.
