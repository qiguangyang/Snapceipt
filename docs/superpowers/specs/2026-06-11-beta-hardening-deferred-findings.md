# Beta-Hardening — Deferred Findings

Findings surfaced by the polish audit (Plan A) that are **out of guardrail**
(spec §8) — logged here, never built in this program.

Format per entry:
- **[area]** short description — _why deferred_ (v1.1 deferral / flow restructuring / new feature / needs product decision) — source PNG.

---

- **[09-quotes]** Quotes list row order is non-deterministic between tour runs — the only static screen the Task 7 pixel-stability check flags as UNSTABLE (`09-quotes/quotes-list-populated.png`). Root cause: both fixture quotes (`draft` "Northbridge Cafe", `sent` "Acme Pty Ltd" in `AppLaunch.swift`) default `createdAt` to `Epoch.nowMs()`, which is pinned to one instant (`Epoch.override`, Task 3), so they share an identical sort key; `QuoteListViewModel.reload()` sorts by `SortDescriptor(\.createdAt, order: .reverse)` with no tiebreaker, so SwiftData returns the tied rows in undefined order and it flips run-to-run. _Why deferred: the fix is a one-line change outside Task 7's "create the checker" scope — either give the two tour-fixture quotes distinct `createdAt` values (Task 2 fixture) or add a stable tiebreaker (e.g. `SortDescriptor(\.id)`) to the QuoteListViewModel fetch. NOT excluded from the checker as "animated" — it is a genuine determinism bug the gate is meant to catch, and a false exclusion would hide it._ — source PNG: `artifacts/tour/stab-{a,b}/09-quotes/quotes-list-populated.png`.
