# BAS History Hub — Design (2026-06-19)

## 1. Goal

Let a GST-registered business user **review, navigate, and lodge prior BAS periods** — not just
the current one — and see an at-a-glance **lodgement log** of which periods are lodged, due, or
not-yet-marked.

This extends the shipped BAS feature (Simpler-BAS spine G1 / 1A / 1B, ABN check, Mark-as-lodged,
accountant pack) documented in `2026-06-14-bas-ready-export-design.md`. Today the period stepper is
a **static label** showing only the current period (per the original spec §4.6, prior-period nav
was deferred). This design un-defers it and adds the history surface.

**Key property — client-only.** This is a pure iOS/client change: **no backend, no migration, no
new sync.** Three facts make that true:

- Storage is already per-period: `BasLocalStore` keys PAYG and the Mark-as-lodged snapshot by
  `periodKey` (`sc.bas.<profileId>.<periodKey>.*`).
- Export is already date-range-driven: `api.exportBas(from:to:)` takes ISO dates, so exporting a
  past quarter already works server-side (the server computes the pack from synced txns in range).
- The window math is a pure anchor-shift: `Period.window(now:startMonth:)` is a pure function of
  the anchor date, so any prior period's window comes from shifting the anchor back N periods.

## 2. Authoritative decisions (do not re-litigate)

1. **Navigation = current-period-first.** The Reports BAS card still opens the **current** period
   (`BasView`, the one you lodge now) — unchanged primary flow. We add (a) an inline ◀/▶ stepper
   and (b) a "Past BAS" link that opens the history list; tapping a history row drills into that
   period.
2. **One `BasView` + one `BasViewModel` with a movable period cursor** — NOT a fresh VM per period.
   Navigation (stepper or history row) just moves the cursor.
3. **Lodgement status tone = soft (trust-first).** The app only knows a period is lodged if the
   user tapped *Mark as lodged*; many users lodge via an accountant / myGov and never mark it. So a
   past unmarked period shows a **neutral "Not marked as lodged"** (amber dot, not red) with a
   one-tap *Mark as lodged* — informative, never accusatory. **No "OVERDUE" language.**
   - Lodged → `Lodged ✓ · <date>` (+ `· figures changed` if drifted).
   - Current / upcoming (due date not yet passed) → `Due <date>`.
   - Past + unmarked (due date passed) → `Not marked as lodged` (amber).
4. **History range** = from the earliest period that has data (a transaction **or** a lodged
   snapshot) up to the current period, **capped at 3 years** (12 quarters / 36 months).
5. **Scope guard** = in-app badges only. **No push / notifications** (push is a separate undecided
   in the GA-readiness notes). **No backend / schema / sync.** The lodged log stays local
   (UserDefaults) in v1.

## 3. Architecture — the period cursor

`BasViewModel` today computes a single `window` in `init` from the injected `now` and never moves
it. We add a cursor and a `move`:

- **`periodOffset: Int`** — `0` = current, `-1` = previous period, … Never positive (forward bound
  is the current period; you don't lodge the future).
- **Anchor-shift** (pure): `monthsPerPeriod = (basPeriod == .quarterly ? 3 : 1)`;
  `anchor = utcCal.date(byAdding: .month, value: periodOffset * monthsPerPeriod, to: now)`;
  `window = p.window(now: anchor, startMonth:)`; `periodKey = BasPeriodKey.make(window:…)`.
  `Period.window` snaps to the period containing the anchor, so a mid-period anchor is fine.
- **On move** (`goToPrevious()` / `goToNext()` / `select(offset:)`): recompute `window` +
  `periodKey`, then reload that period's state from the (already period-keyed) store —
  `paygInstalmentCents = store.paygInstalmentCents(periodKey:)`,
  `lodgedAtMs = store.lodgedSnapshot(periodKey:)?.lodgedAtMs` — then `recompute()`. Everything
  downstream (engine, reconciliation, drift, fromISO/toISO export) is already `window`-driven and
  needs no change.
- **Bounds:** `canGoForward = periodOffset < 0`. `canGoBack = periodOffset > earliestOffset`.
  `earliestOffset` is a **shared pure function**
  (`BasHistory.earliestOffset(txns:lodgedLookup:basPeriod:startMonth:now:cap:)`, `cap = 12`
  quarterly / `36` monthly) used by BOTH the VM (`canGoBack`) and the history builder (§4) so they
  can never disagree. It returns `max(capFloor, deepestDataOffset)` (both ≤ 0) where
  `capFloor = -(cap-1)` and `deepestDataOffset` = the furthest-back offset **within the cap** whose
  period has a transaction **or** a lodged snapshot (`0` if neither — no history). This keeps us
  inside the 3-year cap **and** stops at the earliest period the user actually has history for
  (no empty *pre-history* periods before their first activity).

The existing current-period behavior is **unchanged** at `periodOffset == 0` — the existing BAS
test suite is the regression net.

## 4. Components & contract

- **`BasViewModel`** (extend): `periodOffset`, `goToPrevious()`, `goToNext()`, `select(offset:)`,
  `canGoBack`, `canGoForward`, and a `status` computed (see §5) for the selected period.
  `earliestOffset` is computed once from a `min(txnDate)` query for the profile.
- **`BasHistory`** (new, pure builder): given all profile txns + a lodged-snapshot lookup +
  `basPeriod` / `startMonth` / `now`, returns `[BasHistory.Period]`, most-recent first. Each row =
  `{ offset, window, periodKey, label, dueDate, status, netGstCents, drifted }`. Implementation:
  one txn fetch, bucket by period window, `BasEngine.compute` per bucket. Pure ⇒ unit-testable
  against fixtures. The **headline figure per row is net GST (1A − 1B)**; full breakdown (incl.
  PAYG) lives on the drill-in screen. Rows are **contiguous** `[earliestOffset … 0]` (§3) — a
  no-activity period between two active ones still appears (as `$0`, `Not marked as lodged`), since
  a nil BAS may still be due.
- **`BasHistoryView`** (new): the list, presented as a **`.sheet` from `BasView`**. The current
  period is marked "Current". Tap a row → `vm.select(offset:)` + dismiss the sheet → the existing
  `BasView` re-renders for that period (no second screen / VM).
- **`BasSchedule.dueDate(for:period:)`** (new helper): a period's lodge due date =
  `nextDue(period, on: window.end)` (window.end is exclusive = first instant of the next period;
  `nextDue` returns the first due on/after it = that period's due). Verified for all 4 quarters and
  monthly.
- **`BasView`** (edit): replace the static period label with `◀ [Apr–Jun 2026] ▶` bound to the
  cursor (◀ disabled when `!canGoBack`, ▶ when `!canGoForward`); add a "Past BAS" affordance
  opening the history sheet; show the selected period's status + due date near the header.
- **Router:** no new overlay — the history is a sheet within the existing `.bas` overlay.

## 5. Lodgement status rules (shared by `BasHistory` row and the `BasView` header)

For a period with `window`, `periodKey`, current figures, and injected `now`:

```
dueDate := BasSchedule.dueDate(for: window, period:)
if let snap = lodgedSnapshot(periodKey):
    status = .lodged(at: snap.lodgedAtMs, drifted: figuresDiffer(current, snap))
else if now <= dueDate:
    status = .due(dueDate)            // current / upcoming — neutral
else:
    status = .notMarkedLodged(dueDate) // past + unmarked — amber, never red
```

`figuresDiffer` reuses the existing `BasLocalStore.hasDrifted` comparison (g1/1A/1B/netGst/payg/
total, excluding the timestamp).

## 6. Navigation & presentation flow

```
Reports tab → BAS card → BasView (current period, periodOffset = 0)   ← unchanged
   ├─ ◀ / ▶ stepper            → vm.goToPrevious()/goToNext()  (moves cursor, re-renders)
   └─ "Past BAS" link          → .sheet(BasHistoryView)
                                     └─ tap row → vm.select(offset:) + dismiss → BasView re-renders
```

One VM, one screen; both the stepper and the history list are just cursor moves.

## 7. Testing

Pure builders carry the weight:

- **`BasScheduleDueDateTests`** — `dueDate(for:period:)` for all four quarters (incl. the Dec→28 Feb
  next-year case) and a couple of monthly periods.
- **`BasHistoryTests`** — range/cap bounding (data older than 3y is clamped; no pre-data periods);
  status classification (`lodged` / `due` / `notMarkedLodged`) driven by injected `now` + fixtures;
  `drifted` true when current figures ≠ snapshot; per-period figure bucketing; empty-data ⇒ only the
  current period.
- **`BasViewModelTests`** (additions) — `goToPrevious()`/`goToNext()`/`select(offset:)` move
  `window` + `periodKey` and reload PAYG + lodged for the new period; bounds (`canGoForward == false`
  at offset 0; `canGoBack == false` at `earliestOffset`); **current-period behavior unchanged** at
  offset 0.
- **`BasUITests`** (addition) — step back then forward; open "Past BAS", tap a row, assert the period
  label changed and the figures updated.

## 8. Out of scope / non-goals (v1)

- **No push / notifications / reminders** — in-app badges only.
- **No backend, migration, or sync changes** — export reuses `exportBas(from:to:)`; the lodged log
  stays local (UserDefaults), not synced across devices.
- **No new "overdue"/penalty messaging** — soft framing only (§2.3).
- Editing a past period's transactions remains allowed; corrections surface via the existing **drift**
  indicator and are carried on the next BAS (unchanged from the shipped design).

## 9. Open follow-ups (explicitly deferred, not blockers)

- Syncing the lodged log across devices (would need a new entity / `0005` migration) — out for v1.
- Per-period prior-period nav on the **full worksheet** view — that view isn't built yet (separate
  enhancement).
