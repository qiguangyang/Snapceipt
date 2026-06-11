# Beta-Hardening — Deferred Findings

Findings surfaced by the polish audit (Plan A) that are **out of guardrail**
(spec §8) — logged here, never built in this program.

Format per entry:
- **[area]** short description — _why deferred_ (v1.1 deferral / flow restructuring / new feature / needs product decision) — source PNG.

---

- **[01-onboarding-auth]** area01-02 — selecting the "Business" profile type in the first-profile form does not switch the default accent off personal terracotta (Continue + selected swatch stay orange unless the user manually taps the teal swatch) — _needs product decision: the accent picker is deliberately independent of profile type; auto-defaulting accent on type change is a behavior/UX-default change, not visual polish_ — `artifacts/tour/a01-audit/01-onboarding-auth/onboarding-profile-business.png`.
- **[01-onboarding-auth]** area01-05 — `PermissionPrimingView(.camera)` (and notifications) priming is unreachable in the live first-run flow, so the `permission-priming-camera` tour shot is never produced (RootView gates onboarding on `profileRows.isEmpty`, so inserting the first profile re-renders straight into the shell before OnboardingView can advance to its `.camera` step) — _flow restructuring: making priming reachable requires re-ordering the first-run flow_ — missing `permission-priming-camera.png` (see `ScreenshotTourUITests.swift` test_area01_onboardingAuth comment + `RootView.swift:32`).
