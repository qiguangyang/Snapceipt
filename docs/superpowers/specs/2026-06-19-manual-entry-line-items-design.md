# Manual entry — receipt-style line items

**Date:** 2026-06-19
**Branch:** `feature/manual-entry-line-items`
**Status:** Approved design, ready for implementation plan

## Problem

The "Add manually" screen (`AddManualView`) captures only a single transaction
total (amount, merchant, category, date, note). Scanned receipts, by contrast,
capture individual `LineItem`s (name + price), which are shown in the receipt
detail and synced to D1. A manual entry should offer the same: let the user add
receipt-style line items.

The data layer already exists end to end — `LineItem` (`@Model`, `Syncable`),
its D1 schema, sync enqueue (`entityType: .lineItem`), and the read-only detail
display (`ReceiptDetailView.lineItemsCard`). This feature only adds the **input
UI** on the manual screen and the **save wiring**. No model, sync, or backend
change.

## Goals

- On the manual screen (both Expense and Income), let the user add / edit /
  remove line items (name + price).
- As items are added, the big "Amount" auto-fills to their running sum, but the
  user can override it (e.g. to match a printed total with tax/rounding). This is
  the user-chosen behaviour: *auto-fill, still editable*.
- Persist items as `LineItem` records identical to what the scanner produces, so
  they appear in the receipt detail and sync unchanged.
- Editing an existing manual transaction loads its items and reconciles
  add/edit/remove on save (soft-delete removed rows), mirroring the Quotes editor.

## Non-goals (v1)

- **No per-item quantity field.** Rows are name + price; `LineItem.quantity`
  defaults to `1`, identical to how `ReceiptMapper` stores scanned items today.
- No drag-to-reorder. `sortOrder` follows visual order.
- No change to the scan path, `LineItem` model, sync, or D1 schema.

## Existing pieces this mirrors

- **`ReceiptMapper.map`** (`Features/Capture/ReceiptMapper.swift`) — maps draft
  items → `LineItem(name:, priceCents: cents(price), quantity: 1, sortOrder: index)`.
  Reuse its `cents(_:)` dollars→cents rounding.
- **`QuoteEditorViewModel.saveDraft`** (`Features/Quotes/QuoteEditorViewModel.swift`)
  — the exact add/edit/delete reconciliation pattern: track `originalLineIds`,
  upsert kept/new rows, soft-delete (`deletedAt`/`updatedAt`) removed rows, then
  `enqueue(op:"upsert"/"delete", .lineItem)`.
- **`AddManualView`** (`Features/Capture/Views/AddManualView.swift`) — the screen.
  It is a plain SwiftUI `View` with `@State` and an in-view `save()`; keep that
  shape (no ViewModel extraction).

## Design

### Draft model (in-view `@State`)

A lightweight value type, defers `@Model` creation to save (as the view already
does for `Transaction`):

```swift
struct ItemDraft: Identifiable, Equatable {   // Equatable: drives .onChange(of: items)
    let id: String        // existing LineItem.id when loaded, else ID.uuidv7()
    var name: String
    var priceText: String // decimal string, bound to the price TextField
}
```

`@State private var items: [ItemDraft] = []`
`@State private var originalItemIds: Set<String> = []`
`@State private var amountManuallyEdited = false`

### Pure mapper (unit-testable) — `ManualItemsMapper`

New file `Features/Capture/ManualItemsMapper.swift`, in the `ReceiptMapper` style
(no `ModelContext`):

Three predicates, deliberately split so the sum, the saved set, and validation
can never disagree:

- `static func totalCents(_ items: [ItemDraft]) -> Int` — `Σ cents(priceText)`
  over **all** rows (a blank/invalid price parses to 0, so the amount is literally
  the sum of whatever prices are typed — responsive while typing price-first).
- `static func lineItems(from items: [ItemDraft], txnId: String, userId: String) -> [LineItem]`
  — one `LineItem` per row with a **non-empty trimmed name**: `id: draft.id`,
  `name: trimmed`, `priceCents: ReceiptMapper.cents(price)`, `quantity: 1`,
  `sortOrder: index` (index over the *saved* rows, so it's gap-free).
- `static func hasIncompleteRow(_ items: [ItemDraft]) -> Bool` — true if any row
  has `cents(price) > 0` **and** an empty trimmed name (a priced row that still
  needs a description). Drives `canSave`.

Reuses `ReceiptMapper.cents`. Because Save is blocked while any priced row is
unnamed, by the time a save is allowed every priced row is named — so
`totalCents` (auto-filled amount) and the persisted items always reconcile.

The view does the context insert/enqueue and the diff (mirroring the Quotes
editor) — that part stays in `save()` and is covered by XCUI.

### Amount ↔ items behaviour

- `amountManuallyEdited` defaults `false`.
- The amount `TextField` binds through a custom `Binding` whose **setter** sets
  `amount = newValue; amountManuallyEdited = true`. User typing → flag flips true.
- `.onChange(of: items)` (fires on add/remove and any name/price edit, since
  `ItemDraft` is `Equatable`): if `!amountManuallyEdited`, write the items total
  **directly to the `amount` `@State`** (not via the binding setter), so it
  doesn't trip the flag. Format as 2-dp / no grouping (matching `loadIfEditing`);
  when `totalCents == 0`, set `amount = ""` so the `0.00` placeholder shows rather
  than a literal "0.00".
- When `amountManuallyEdited == true` **and** `totalCents > 0` **and** it differs
  from the entered amount magnitude, show a subtle **"Use items total $X"** chip
  under the amount; tapping it sets `amount` to the formatted total and clears the
  flag (re-engaging auto-fill).
- **Edit mode:** `loadIfEditing()` loads the transaction amount and sets
  `amountManuallyEdited = true` (a loaded total is authoritative — never silently
  clobbered). The chip still lets the user resync to the items total.

### UI — "Items" card

A new card placed **below** the merchant/date/note `fieldsCard`, before the save
bar, matching the existing `Card` aesthetic:

- **Zero state:** card shows just a ghost `+ Add item` row in the accent tint.
- **Row:** `[tag icon] [ "Item name" TextField …… ] [ "$" price TextField ] [×]`.
  Hairline `Palette.line2` dividers between rows; `+ Add item` pinned at bottom.
  `×` removes the row (no swipe — the screen is a `ScrollView`, not a `List`).
- Available in **both** Expense and Income mode (model is symmetric; items sum
  into the positive income amount). Income keeps the same "Items" label.
- New accessibility identifiers: `manual.items.add`, and per-row
  `manual.item.name.<i>`, `manual.item.price.<i>`, `manual.item.remove.<i>`, plus
  `manual.items.useTotal` for the chip. Add to `AccessibilityID`.

### Save (in `save()`, mirroring `QuoteEditorViewModel.saveDraft`)

Both create and edit paths, after the `Transaction` is inserted/updated and has a
stable `txn.id`:

1. `let desired = ManualItemsMapper.lineItems(from: items, txnId: txn.id, userId: userId)`
   (drops blank rows).
2. `keptIds = Set(desired.map(\.id))`. For each desired item: if an existing
   `LineItem` with that id exists, update its fields (`name`, `priceCents`,
   `quantity`, `sortOrder`, `updatedAt`); else `context.insert` it.
3. `removed = originalItemIds.subtracting(keptIds)`: fetch each, set
   `deletedAt`/`updatedAt`, collect.
4. `context.save()`, then `enqueue(op:"upsert", .lineItem)` for each desired item
   and `enqueue(op:"delete", .lineItem)` for each removed row.
5. `originalItemIds = keptIds`.

In create mode `originalItemIds` is empty, so step 3 is a no-op.

### Validation

- A **blank** row (empty name AND empty/zero price) is harmless: it contributes 0
  to the sum and is dropped from save.
- A row with a **price but no name** is *incomplete* (`hasIncompleteRow`): it
  blocks Save and shows a gentle inline hint on the row. Every receipt line has a
  description.
- A named row with **$0** is allowed and saved.
- `canSave` becomes `amountCents != 0 && merchant non-empty && !hasIncompleteRow`.
  With auto-fill, a priced item makes `amountCents != 0` naturally.

## Testing

- **Unit (`SnapceiptTests/ManualItemsMapperTests.swift`):**
  `totalCents` sums all rows' prices incl. decimals/rounding (via
  `ReceiptMapper.cents`) and treats blank/invalid price as 0; `lineItems` drops
  unnamed rows, trims names, sets `quantity: 1`, gives gap-free `sortOrder`, and
  carries the draft id; `hasIncompleteRow` is true for a priced unnamed row and
  false for blank rows, named-$0 rows, and fully-named priced rows.
- **XCUI (extend the manual flow in `SnapceiptUITests`):** add two items →
  assert amount auto-sums; override the amount → assert it freezes when more
  items change; save → open the receipt detail → assert items listed; edit the
  transaction → remove an item → save → assert it's gone (soft-deleted).
- Keep the existing 101 UI / 105 unit suites green.

## Files

- `Snapceipt/Features/Capture/Views/AddManualView.swift` — items card, draft
  state, amount auto-fill, save wiring, `canSave`, `loadIfEditing` item load.
- `Snapceipt/Features/Capture/ManualItemsMapper.swift` — **new**, pure mapper.
- `AccessibilityID` (wherever `manual.*` ids live) — new item ids.
- `SnapceiptTests/ManualItemsMapperTests.swift` — **new**, unit tests.
- `SnapceiptUITests/...` — extend the manual-entry UI flow.

No model / sync / backend files change.
