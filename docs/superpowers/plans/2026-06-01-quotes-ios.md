# F5 — Quotes — iOS Implementation Plan

> **REQUIRED SUB-SKILL:** Execute this plan with **superpowers:subagent-driven-development**. Each task below is a self-contained, dependency-ordered unit: write the failing test, run it RED, implement (full code shown — no placeholders), run it GREEN, commit. Do not skip the RED step; do not weaken assertions to make a test pass.

**Goal:** Ship a **Business-profile-only** quote builder for AU sole traders. From a Home "Create Quote" quick action (shown only when the active profile is Business) → a **quotes list** → a **create/edit editor** (a saved bill-to client, inline-editable line items, a GST 10% toggle, live totals) → **Send**. Send calls `POST /quotes/:id/send`; the backend assigns a sequential `SN-####`, renders a PDF, and emails the client; the editor applies the response (number/status/sentAt/totals) and shows a success overlay. A new saved-clients address book (a synced `Client` entity) with a picker + inline "New client" backs the bill-to field.

**Architecture:** F5 adds iOS UI + view-models + pure helpers + one new synced entity (`Client`). The `Quote` + `QuoteLineItem` `@Model`s, `EntityType.quote`/`.quoteLineItem`, and `QuoteSyncMapper`/`QuoteLineItemSyncMapper` **already exist** and round-trip via the generic `/sync/push`+`/sync/pull` (verified in `Snapceipt/Sync/SyncEntityRegistry.swift` lines 487–569 and `Snapceipt/Model/Entities/{Quote,QuoteLineItem}.swift`) — quote/line-item CRUD needs **no new persistence or sync code**, and the scaffolded `@Model`s + their `init` labels are **not changed**. The only new persistence is the `Client` entity (`EntityType.client` + `ClientSyncMapper` + `ModelContainer` registration; the matching `clients` D1 table is the backend plan's job). The only new network endpoint is `APIClient.sendQuote(_:)` (`POST /quotes/:id/send`). Three router surfaces: two full-screen `Overlay` cases (`.quotes`, `.quoteEditor(id:)`) presented via `ShellView.overlay` and dismissed via `dismissOverlay()`, mirroring `.budgets`/`.budgetEditor`; the client picker is a `.sheet` **local to the editor** (not a router overlay). A Home "Create Quote" quick action (`"receipt"` glyph — there is no `"doc"` glyph in `Icons.swift`; an unknown name renders blank — `home.quick.quote`) opens the list — **rendered only when the active `Profile.type == "business"`**. Every quote/client query + create is scoped by the active `profileId` (never nil, never by `mode`/`type`): the editor/picker VMs always set `profileId` non-nil, closing the `Quote.profileId?` (Swift `Optional`) vs D1 `NOT NULL` gap. **Line items are a SEPARATE synced entity** — `saveDraft()` diffs the working set against the persisted rows and enqueues an `upsert`/`delete` per item. CRUD goes through the existing `SyncEnqueuing.enqueue(op:entityType:entity:)` seam (optimistic local-first, soft-delete tombstones, LWW).

**Tech Stack:** Swift 5.9+/iOS 17, SwiftUI, SwiftData (`@Model`, `FetchDescriptor`, `#Predicate`), Swift Testing (`@Suite`/`@Test`/`#expect`) for unit tests, XCUITest for hermetic UI tests, `URLSession` (the existing `LiveAPIClient` plumbing), `UIActivityViewController` (the `ExportSheet`/`ActivityView` share pattern, reused for the optional "View PDF" when email is off). Project files are globbed by XcodeGen — run `/opt/homebrew/bin/xcodegen generate` before every `xcodebuild` (and again after adding any new file).

**Rule:** No placeholders. Every implementation step shows full code. References are only to symbols defined in a prior task or verified to already exist in the codebase. The scaffolded `Quote`/`QuoteLineItem` `@Model`s and their `init` argument labels are treated as frozen contract and are never edited.

---

## File structure

### Created

| Path | Responsibility |
| --- | --- |
| `Snapceipt/Model/Entities/Client.swift` | `@Model final class Client: Syncable` — the saved-clients address book (`id`/`userId`/`profileId?`/`name`/`email?` + envelope), `entityType => .client`. Mirrors `Budget`/`LoyaltyCard` shape. |
| `Snapceipt/Features/Quotes/QuoteStatus.swift` | `enum QuoteStatus: String` (`draft`/`sent`/`accepted`/`declined`/`expired`/`invoiced`) + `Quote.statusValue` computed bridge over the raw `status` String (storage unchanged). The F4 `BarcodeFormat` pattern. |
| `Snapceipt/Features/Quotes/QuoteTotals.swift` | Pure `QuoteTotals.compute(lineItems:gstEnabled:) -> (subtotal: Int, gst: Int, total: Int)` (§4.2). No SwiftUI/SwiftData, no hidden time. |
| `Snapceipt/Features/Quotes/QuoteListViewModel.swift` | `@Observable @MainActor`; injected `context/sync/userId/profileId`; `quotes` (profile-scoped, newest first), `reload()`, `delete(_:)` (soft-delete + enqueue). |
| `Snapceipt/Features/Quotes/QuoteEditorViewModel.swift` | `@Observable @MainActor`; `load(id?)`, working `[QuoteLineItem]` set, `gstEnabled`, client snapshot (`clientName`/`clientEmail`), computed `totals` (via `QuoteTotals`), `saveDraft()` (upsert quote + diff line items → enqueue per item), `canSend`, `send(api:)` (saveDraft → `api.sendQuote(id)` → apply response → save). The meatiest VM. |
| `Snapceipt/Features/Quotes/ClientPickerViewModel.swift` | `@Observable @MainActor`; profile-scoped `clients`, `reload()`, `create(name:email:)` + enqueue, `filtered(search:)`. |
| `Snapceipt/Features/Quotes/QuoteListView.swift` | List screen (`LbHeader`, rows [client · `fmt(total)` · status badge · date], `EmptyArt`, `LbFloatingCTA "New quote"`). |
| `Snapceipt/Features/Quotes/QuoteEditorView.swift` | Editor (`SheetHeader` + `SN-####` badge; bill-to card → `ClientPickerSheet`; inline line-item rows add/remove; GST toggle; live totals card; validity note; Send with in-flight/error; success overlay → "View PDF" via `ActivityView` when `emailed:false`). |
| `Snapceipt/Features/Quotes/ClientPickerSheet.swift` | Saved clients + search + inline "New client" (`.sheet`-presented; calls back with the picked/created client). |
| `SnapceiptTests/ClientModelTests.swift` | `Client` `@Model` + `EntityType.client` + `ClientSyncMapper` round-trip tests. |
| `SnapceiptTests/QuoteStatusTests.swift` | `QuoteStatus` bridge round-trip + unknown → nil. |
| `SnapceiptTests/QuoteTotalsTests.swift` | `QuoteTotals.compute` (subtotal, GST rounding, GST-off). |
| `SnapceiptTests/SendQuoteResponseTests.swift` | `SendQuoteResponse` decode + `MockAPIClient` records the `sendQuote` call (the `updateDevice` mirror). |
| `SnapceiptTests/ClientPickerViewModelTests.swift` | `ClientPickerViewModel` create+enqueue, profile-scope. |
| `SnapceiptTests/QuoteListViewModelTests.swift` | `QuoteListViewModel` profile-scope newest-first, delete+enqueue. |
| `SnapceiptTests/QuoteEditorViewModelTests.swift` | `QuoteEditorViewModel` load, save-draft line-item diffing + enqueue, totals, `canSend`, `send` applies the `MockAPIClient` response. |
| `SnapceiptUITests/QuotesUITests.swift` | Hermetic seeded UI test: Home Create Quote → list → new editor → pick seeded client → add line item → toggle GST → Send (Stub) → success → Done → Home (overlays are single-slot + mutually exclusive, so Done returns to Home, not the list — mirrors BudgetsUITests). |

### Modified

| Path | Change |
| --- | --- |
| `Snapceipt/Model/EntityType.swift` | Add `case client` (+ bump the "14 syncable…" doc comment to 15). |
| `Snapceipt/Model/ModelContainer+Snapceipt.swift` | Register `Client.self` in `SnapceiptSchema.models` (+ bump the "14 syncable domain models" doc comment to 15). |
| `SnapceiptTests/EntityTypeTests.swift` | **Update existing asserts** (Task 1): `count` 14→15; append `"client"` to the `rawValues` expected array. (No net test count change.) |
| `SnapceiptTests/SwiftDataModelTests.swift` | **Update existing assert** (Task 1): `entityTypeCount` 14→15 (+ its display string). (No net test count change.) |
| `Snapceipt/Sync/SyncEntityRegistry.swift` | Add `ClientSyncMapper` + `register(.client, ClientSyncMapper())` + `Client: SyncableMutableEnvelope, MutableSyncRow`. |
| `Snapceipt/Sync/DTOs.swift` | Add `struct SendQuoteResponse: Decodable`. |
| `Snapceipt/Sync/APIClient.swift` | Add `sendQuote(_:)` to the protocol + `LiveAPIClient` (`POST /quotes/:id/send`). |
| `Snapceipt/Sync/StubAPIClient.swift` | Add `sendQuote(_:)` (deterministic stub). |
| `Snapceipt/Features/Auth/SignInView.swift` | Add `sendQuote(_:)` to `PreviewAPIClient`. |
| `SnapceiptTests/Mocks/MockAPIClient.swift` | Add `sendQuote(_:)` handler + recorded `sendQuoteCalls`. |
| `Snapceipt/Shared/AccessibilityID.swift` | Add the §4.6 ids + `home.quick.quote`. |
| `Snapceipt/App/Router.swift` | Add `.quotes` + `.quoteEditor(id: String?)` `Overlay` cases + their `id` strings + an `openQuote(_:)` convenience. |
| `Snapceipt/App/RootView.swift` | Add the Business-only Home "Create Quote" quick action; render `.quotes`/`.quoteEditor` overlays in `ShellView.overlay`; add the new cases to `sheetContent` (EmptyView arm) + the `sheetBinding`/`sheetContent` full-screen exclusion sets (incl. `hasPrefix("quoteEditor")`). |
| `Snapceipt/App/AppLaunch.swift` | Seed a `Client` + a `Quote` (+ one line item) on the active business profile `p1` under `-uiTestSeed`. |

XcodeGen globs new files automatically; **never `git add` the `.xcodeproj`** (xcodegen-generated + git-ignored).

---

## Conventions for every task

- **Build/test commands** (run from the repo root; tools use absolute paths):
  - Regenerate the project before building, and again after adding any new file:
    ```
    /opt/homebrew/bin/xcodegen generate
    ```
  - Run a single unit suite (the `-only-testing` selector MUST use the Swift **type** name, never the `@Suite` display string):
    ```
    xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/QuoteTotalsTests test
    ```
  - Run a single UI suite:
    ```
    xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptUITests/QuotesUITests test
    ```
  - For views with no unit test, gate on a full build + the existing UI suite:
    ```
    xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' build
    ```
- **SourceKit file-level diagnostics are unreliable here** (no module context). Trust `xcodebuild` output only.
- **Commit each task.** End every commit message with the trailer:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  ```
- **Baselines at planning time:** iOS unit **279**, UI **10** (1 LiveSmoke skip). Each task states the expected new per-suite counts; the final gate confirms the new totals.

---

## Task 1 — `Client` `@Model` + `EntityType.client` + `ModelContainer` registration

**Files**
- Create `Snapceipt/Model/Entities/Client.swift`
- Modify `Snapceipt/Model/EntityType.swift`
- Modify `Snapceipt/Model/ModelContainer+Snapceipt.swift`
- Create `SnapceiptTests/ClientModelTests.swift`
- Modify `SnapceiptTests/EntityTypeTests.swift` (the two existing assertions hard-code "14 cases" + the exact raw-value array — both MUST be updated to 15 / include `"client"`, or this Task's GREEN goes RED on them)
- Modify `SnapceiptTests/SwiftDataModelTests.swift` (the `entityTypeCount` test also hard-codes `EntityType.allCases.count == 14` — bump to 15)

> **CRITICAL (verified against the real codebase):** adding `case client` makes `EntityType.allCases.count == 15`. Three existing assertions hard-code 14 and WILL FAIL unless updated in THIS task:
> - `SnapceiptTests/EntityTypeTests.swift` `count()` → `#expect(EntityType.allCases.count == 15)`.
> - `SnapceiptTests/EntityTypeTests.swift` `rawValues()` → append `"client"` to the `expected` array (it is the last `allCases` element, matching the enum order below).
> - `SnapceiptTests/SwiftDataModelTests.swift` `entityTypeCount()` (≈ line 139) + its `@Test` display string → `#expect(EntityType.allCases.count == 15)`.
> Also bump the doc comments that say "The 14 syncable entity types" (`EntityType.swift`) and "the 14 syncable domain models" (`ModelContainer+Snapceipt.swift`) to 15. These three test edits net **zero** new tests (they are existing tests kept green), so they do not change the per-task count math.

**Steps**

1. Write the failing test `SnapceiptTests/ClientModelTests.swift`:
   ```swift
   import Testing
   import Foundation
   import SwiftData
   @testable import Snapceipt

   @MainActor
   @Suite("Client model")
   struct ClientModelTests {
       @Test("Client defaults: entityType is .client, profileId/email start as passed-in")
       func defaults() throws {
           let c = Client(userId: "u1", profileId: "p1", name: "Acme Pty Ltd", email: "ap@acme.com")
           #expect(c.entityType == .client)
           #expect(c.userId == "u1")
           #expect(c.profileId == "p1")
           #expect(c.name == "Acme Pty Ltd")
           #expect(c.email == "ap@acme.com")
           #expect(c.deletedAt == nil)
           #expect(c.rev == 0)
       }

       @Test("Client persists + round-trips through a SwiftData context scoped by profileId")
       func persists() throws {
           let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
           let ctx = ModelContext(container)
           ctx.insert(Client(userId: "u1", profileId: "p1", name: "A", email: nil))
           ctx.insert(Client(userId: "u1", profileId: "p2", name: "B", email: "b@x.com"))
           try ctx.save()
           let pid = "p1"
           let rows = try ctx.fetch(FetchDescriptor<Client>(
               predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil }))
           #expect(rows.count == 1)
           #expect(rows[0].name == "A")
           #expect(rows[0].email == nil)
       }

       @Test("EntityType has a .client case with the camelCase raw value 'client'")
       func entityTypeCase() {
           #expect(EntityType.client.rawValue == "client")
           #expect(EntityType.allCases.contains(.client))
       }
   }
   ```

2. Run it RED (the file won't compile — `Client` and `.client` don't exist yet):
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/ClientModelTests test
   ```

3. Implement `Snapceipt/Model/Entities/Client.swift`:
   ```swift
   import Foundation
   import SwiftData

   /// A saved client in the per-profile address book (Business). Mirrors D1 `clients`.
   /// Picking a Client copies its name/email onto the quote (no FK), keeping a sent
   /// quote stable. v1 carries only name + email (no phone/address/ABN).
   @Model
   final class Client: Syncable {
       @Attribute(.unique) var id: String
       var userId: String
       var profileId: String?

       var name: String
       var email: String?

       var createdAt: Int
       var updatedAt: Int
       var deletedAt: Int?
       var rev: Int
       var lastEditedDeviceId: String?

       var entityType: EntityType { .client }

       init(
           id: String = Snapceipt.ID.uuidv7(),
           userId: String,
           profileId: String?,
           name: String,
           email: String? = nil,
           createdAt: Int = Epoch.nowMs(),
           updatedAt: Int = Epoch.nowMs(),
           deletedAt: Int? = nil,
           rev: Int = 0,
           lastEditedDeviceId: String? = nil
       ) {
           self.id = id
           self.userId = userId
           self.profileId = profileId
           self.name = name
           self.email = email
           self.createdAt = createdAt
           self.updatedAt = updatedAt
           self.deletedAt = deletedAt
           self.rev = rev
           self.lastEditedDeviceId = lastEditedDeviceId
       }
   }
   ```

   Add `case client` to `Snapceipt/Model/EntityType.swift`. The enum is `CaseIterable`; add the new case at the end and bump the comment count from 14 to 15. Replace the leading comment + the whole enum body as follows:
   ```swift
   /// The 15 syncable entity types. Raw values are the camelCase strings the
   /// backend `SYNCABLE_TABLES` keys + `PushMutation.entityType` use verbatim.
   enum EntityType: String, CaseIterable, Codable, Sendable {
       case transaction
       case lineItem
       case profile
       case category
       case smartRule
       case budget
       case loyaltyCard
       case quote
       case quoteLineItem
       case mileageTrip
       case wfhLog
       case taxSettings
       case vehicle
       case vehicleYear
       case client
   }
   ```

   Register `Client.self` in `Snapceipt/Model/ModelContainer+Snapceipt.swift` — add it to the `models` array (after `VehicleYear.self`, before `OutboxMutation.self`), and bump the file's leading doc comment from "the 14 syncable domain models" to "the 15 syncable domain models":
   ```swift
       static let models: [any PersistentModel.Type] = [
           Profile.self,
           Transaction.self,
           LineItem.self,
           Category.self,
           SmartRule.self,
           Budget.self,
           LoyaltyCard.self,
           MileageTrip.self,
           WFHLog.self,
           Quote.self,
           QuoteLineItem.self,
           TaxSettings.self,
           Vehicle.self,
           VehicleYear.self,
           Client.self,
           OutboxMutation.self,
           PendingReceipt.self,
       ]
   ```

4. Update the THREE existing assertions that hard-code "14 cases" (so they stay GREEN with `.client` added). These are existing tests, not new ones — no count change.

   `SnapceiptTests/EntityTypeTests.swift` — bump the count and append `"client"` to the raw-value array:
   ```swift
       @Test("has exactly the 15 syncable cases")
       func count() {
           #expect(EntityType.allCases.count == 15)
       }

       @Test("raw values match the backend camelCase contract")
       func rawValues() {
           let expected = [
               "transaction", "lineItem", "profile", "category", "smartRule",
               "budget", "loyaltyCard", "quote", "quoteLineItem",
               "mileageTrip", "wfhLog", "taxSettings", "vehicle", "vehicleYear",
               "client",
           ]
           #expect(EntityType.allCases.map(\.rawValue) == expected)
       }
   ```

   `SnapceiptTests/SwiftDataModelTests.swift` — bump the `entityTypeCount` test (≈ line 137-140), display string included:
   ```swift
       @Test("EntityType still has exactly the 15 syncable cases")
       func entityTypeCount() {
           #expect(EntityType.allCases.count == 15)
       }
   ```

5. Run it GREEN (run the impacted existing suites too, not just `ClientModelTests`):
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/ClientModelTests test
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/EntityTypeTests test
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/SwiftDataModelTests test
   ```

6. Commit:
   ```
   git add Snapceipt/Model/Entities/Client.swift Snapceipt/Model/EntityType.swift Snapceipt/Model/ModelContainer+Snapceipt.swift SnapceiptTests/ClientModelTests.swift SnapceiptTests/EntityTypeTests.swift SnapceiptTests/SwiftDataModelTests.swift
   git commit -m "F5: Client @Model + EntityType.client + container registration

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

**Expected suite count after this task:** `SnapceiptTests` = 279 + 3 (`ClientModelTests`) = **282** (the three `.client` assertion edits keep existing tests green; they add no new tests).

---

## Task 2 — `ClientSyncMapper` in `SyncEntityRegistry`

**Files**
- Modify `Snapceipt/Sync/SyncEntityRegistry.swift`
- Modify `SnapceiptTests/ClientModelTests.swift` (add the mapper round-trip test to the existing suite)

**Steps**

1. Add a failing round-trip test to `SnapceiptTests/ClientModelTests.swift` (inside the existing `ClientModelTests` struct). It exercises the registry's encode (`payload`) → outbox JSON → `decodePayload` → upsert path the same way the Budget/LoyaltyCard mappers are covered:
   ```swift
       @Test("ClientSyncMapper payload round-trips name/email + the shared envelope")
       func mapperRoundTrip() throws {
           let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
           let ctx = ModelContext(container)
           let registry = SyncEntityRegistry()
           let src = Client(userId: "u1", profileId: "p1", name: "Acme", email: "ap@acme.com")
           src.rev = 3
           ctx.insert(src)
           try ctx.save()

           // Encode -> payload string -> decode back into a wire dict.
           let json = registry.encodePayload(entityType: .client, entity: src)
           let fields = registry.decodePayload(json)
           #expect(fields["name"]?.stringValue == "Acme")
           #expect(fields["email"]?.stringValue == "ap@acme.com")
           #expect(fields["id"]?.stringValue == src.id)
           #expect(fields["profileId"]?.stringValue == "p1")
           #expect(fields["rev"]?.intValue == 3)
       }

       @Test("ClientSyncMapper upserts a pulled envelope into a Client row")
       func mapperUpsert() throws {
           let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
           let ctx = ModelContext(container)
           let registry = SyncEntityRegistry()
           let envJSON = """
           {"type":"client","id":"c-1","userId":"u1","profileId":"p1",
            "name":"Beta Co","email":"beta@co.com",
            "createdAt":1,"updatedAt":2,"deletedAt":null,"rev":5,"lastEditedDeviceId":null}
           """
           let env = try JSONDecoder().decode(PullChange.self, from: Data(envJSON.utf8))
           registry.handler(for: .client)?.applyPulled(ctx, env)
           try ctx.save()
           let rows = try ctx.fetch(FetchDescriptor<Client>())
           #expect(rows.count == 1)
           #expect(rows[0].id == "c-1")
           #expect(rows[0].name == "Beta Co")
           #expect(rows[0].email == "beta@co.com")
           #expect(rows[0].rev == 5)
       }
   ```

2. Run it RED (the `.client` handler is unregistered, so `handler(for: .client)` is nil and `encodePayload` falls through to `sharedFields` which omits `name`/`email`):
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/ClientModelTests test
   ```

3. Implement the mapper in `Snapceipt/Sync/SyncEntityRegistry.swift`. Register it in `init()` (add after the `register(.vehicleYear, …)` line):
   ```swift
           register(.vehicleYear, VehicleYearSyncMapper())
           register(.client, ClientSyncMapper())
   ```
   Add the mapper + the `MutableSyncRow` conformance at the end of the file (after the `VehicleYear` MARK section), mirroring `BudgetSyncMapper`:
   ```swift
   // MARK: - Client

   private struct ClientSyncMapper: SyncRowMapper {
       func upsert(_ context: ModelContext, _ env: PullChange) {
           let row = fetch(context, env.id) ?? {
               let x = Client(userId: env.userId, profileId: env.profileId,
                              name: env.string("name") ?? "")
               x.id = env.id
               context.insert(x)
               return x
           }()
           applySharedEnvelope(row, env)
           row.profileId = env.profileId
           if let v = env.string("name") { row.name = v }
           if let v = env.string("email") { row.email = v }
       }

       func payload(_ r: Client) -> [String: JSONValue] {
           var f = sharedFields(r)
           f["name"] = .string(r.name)
           f["email"] = str(r.email)
           return f
       }
   }

   extension Client: SyncableMutableEnvelope, MutableSyncRow {
       func setRev(_ rev: Int) { self.rev = rev }
       func setUpdatedAt(_ updatedAt: Int) { self.updatedAt = updatedAt }
   }
   ```

4. Run it GREEN:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/ClientModelTests test
   ```

5. Commit:
   ```
   git add Snapceipt/Sync/SyncEntityRegistry.swift SnapceiptTests/ClientModelTests.swift
   git commit -m "F5: ClientSyncMapper (upsert + payload) registered for .client

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

> The backend `clients` table + `'client'` registration in the backend sync registry are the backend plan's job; this Task only wires the iOS round-trip. End-to-end `Client` sync is covered by the backend `e2e/quotes.e2e` schema/round-trip test.

**Expected suite count after this task:** `SnapceiptTests` = 282 + 2 = **284**.

---

## Task 3 — `QuoteStatus` enum + `Quote.statusValue` bridge

**Files**
- Create `Snapceipt/Features/Quotes/QuoteStatus.swift`
- Create `SnapceiptTests/QuoteStatusTests.swift`

**Steps**

1. Write the failing test `SnapceiptTests/QuoteStatusTests.swift`:
   ```swift
   import Testing
   import Foundation
   @testable import Snapceipt

   @Suite("QuoteStatus bridge")
   struct QuoteStatusTests {
       @Test("all six statuses round-trip through the raw String storage")
       func roundTrip() {
           for s in QuoteStatus.allCases {
               let q = Quote(userId: "u1", profileId: "p1", status: s.rawValue)
               #expect(q.statusValue == s)
           }
       }

       @Test("setting statusValue writes the raw string")
       func setter() {
           let q = Quote(userId: "u1", profileId: "p1")
           q.statusValue = .sent
           #expect(q.status == "sent")
           #expect(q.statusValue == .sent)
       }

       @Test("an unknown raw status reads back as nil")
       func unknownIsNil() {
           let q = Quote(userId: "u1", profileId: "p1", status: "garbage")
           #expect(q.statusValue == nil)
       }

       @Test("raw values match the D1 CHECK enum exactly")
       func rawValues() {
           #expect(QuoteStatus.draft.rawValue == "draft")
           #expect(QuoteStatus.sent.rawValue == "sent")
           #expect(QuoteStatus.accepted.rawValue == "accepted")
           #expect(QuoteStatus.declined.rawValue == "declined")
           #expect(QuoteStatus.expired.rawValue == "expired")
           #expect(QuoteStatus.invoiced.rawValue == "invoiced")
       }
   }
   ```

2. Run it RED:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/QuoteStatusTests test
   ```

3. Implement `Snapceipt/Features/Quotes/QuoteStatus.swift` (storage stays the raw `String`; this only bridges read/write — the F4 `BarcodeFormat` pattern):
   ```swift
   import Foundation

   /// The six quote lifecycle states. Raw values are the exact strings stored in
   /// `Quote.status` (and validated by the D1 CHECK server-side). `accepted`/`invoiced`
   /// are modeled for the post-v1 invoice flow but unused by the v1 UI.
   enum QuoteStatus: String, CaseIterable, Sendable {
       case draft
       case sent
       case accepted
       case declined
       case expired
       case invoiced

       /// Short label for the list status badge.
       var label: String {
           switch self {
           case .draft: return "Draft"
           case .sent: return "Sent"
           case .accepted: return "Accepted"
           case .declined: return "Declined"
           case .expired: return "Expired"
           case .invoiced: return "Invoiced"
           }
       }
   }

   extension Quote {
       /// Typed view over the raw `status` storage. Storage stays `String` for sync
       /// symmetry; this only bridges read/write to the enum (nil for an unknown value).
       var statusValue: QuoteStatus? {
           get { QuoteStatus(rawValue: status) }
           set { if let newValue { status = newValue.rawValue } }
       }
   }
   ```

4. Run it GREEN:
   ```
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/QuoteStatusTests test
   ```

5. Commit:
   ```
   git add Snapceipt/Features/Quotes/QuoteStatus.swift SnapceiptTests/QuoteStatusTests.swift
   git commit -m "F5: QuoteStatus enum + Quote.statusValue bridge

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

**Expected suite count after this task:** `SnapceiptTests` = 284 + 4 = **288**.

---

## Task 4 — `QuoteTotals` pure helper

**Files**
- Create `Snapceipt/Features/Quotes/QuoteTotals.swift`
- Create `SnapceiptTests/QuoteTotalsTests.swift`

**Steps**

1. Write the failing test `SnapceiptTests/QuoteTotalsTests.swift`. The helper takes a lightweight `(quantity, unitPriceCents)` input so it stays pure (no `@Model`/SwiftData dependency) and the same formula the backend recomputes (§4.2):
   ```swift
   import Testing
   import Foundation
   @testable import Snapceipt

   @Suite("QuoteTotals.compute")
   struct QuoteTotalsTests {
       private func line(_ qty: Int, _ unit: Int) -> QuoteTotals.Line {
           QuoteTotals.Line(quantity: qty, unitPriceCents: unit)
       }

       @Test("subtotal sums quantity * unitPriceCents across lines")
       func subtotal() {
           let r = QuoteTotals.compute(lineItems: [line(2, 5_00), line(3, 10_00)], gstEnabled: false)
           #expect(r.subtotal == 40_00)   // 2*500 + 3*1000
           #expect(r.gst == 0)
           #expect(r.total == 40_00)
       }

       @Test("GST is 10% of subtotal, rounded to the nearest cent")
       func gstRounding() {
           // subtotal 33_33 -> 10% = 333.3 -> round -> 333
           let r = QuoteTotals.compute(lineItems: [line(1, 33_33)], gstEnabled: true)
           #expect(r.subtotal == 33_33)
           #expect(r.gst == 3_33)
           #expect(r.total == 36_66)
       }

       @Test("GST rounds half up at the .5 boundary")
       func gstHalfUp() {
           // subtotal 5 cents -> 10% = 0.5 -> round -> 1
           let r = QuoteTotals.compute(lineItems: [line(1, 5)], gstEnabled: true)
           #expect(r.gst == 1)
           #expect(r.total == 6)
       }

       @Test("GST off yields zero gst and total == subtotal")
       func gstOff() {
           let r = QuoteTotals.compute(lineItems: [line(1, 100_00)], gstEnabled: false)
           #expect(r.gst == 0)
           #expect(r.total == 100_00)
       }

       @Test("empty line items yield all zeros")
       func empty() {
           let r = QuoteTotals.compute(lineItems: [], gstEnabled: true)
           #expect(r.subtotal == 0 && r.gst == 0 && r.total == 0)
       }
   }
   ```

2. Run it RED:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/QuoteTotalsTests test
   ```

3. Implement `Snapceipt/Features/Quotes/QuoteTotals.swift` (pure; matches the backend formula in §4.2 — `round(Double(subtotal) * 0.10)`):
   ```swift
   import Foundation

   /// Pure quote-totals math, shared by the live editor UI and asserted to match the
   /// backend send route (§4.2). GST is quote-level (per `gstEnabled`), 10% AU, rounded
   /// to the nearest cent (half-up).
   enum QuoteTotals {
       /// A minimal line input (decoupled from the `QuoteLineItem` @Model so the helper
       /// stays pure + trivially testable).
       struct Line {
           let quantity: Int
           let unitPriceCents: Int
       }

       /// subtotal = Σ(quantity × unitPriceCents); gst = round(subtotal × 0.10) iff enabled;
       /// total = subtotal + gst. All in integer cents.
       static func compute(lineItems: [Line], gstEnabled: Bool) -> (subtotal: Int, gst: Int, total: Int) {
           let subtotal = lineItems.reduce(0) { $0 + $1.quantity * $1.unitPriceCents }
           let gst = gstEnabled ? Int((Double(subtotal) * 0.10).rounded()) : 0
           return (subtotal, gst, subtotal + gst)
       }

       /// Convenience overload for the editor: maps `QuoteLineItem`s to `Line`s.
       static func compute(lineItems: [QuoteLineItem], gstEnabled: Bool) -> (subtotal: Int, gst: Int, total: Int) {
           compute(lineItems: lineItems.map { Line(quantity: $0.quantity, unitPriceCents: $0.unitPriceCents) },
                   gstEnabled: gstEnabled)
       }
   }
   ```

4. Run it GREEN:
   ```
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/QuoteTotalsTests test
   ```

5. Commit:
   ```
   git add Snapceipt/Features/Quotes/QuoteTotals.swift SnapceiptTests/QuoteTotalsTests.swift
   git commit -m "F5: QuoteTotals pure helper (subtotal/GST/total)

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

**Expected suite count after this task:** `SnapceiptTests` = 288 + 5 = **293**.

---

## Task 5 — `APIClient.sendQuote` + `SendQuoteResponse` DTO + all 4 conformers

**Files**
- Modify `Snapceipt/Sync/DTOs.swift`
- Modify `Snapceipt/Sync/APIClient.swift`
- Modify `Snapceipt/Sync/StubAPIClient.swift`
- Modify `Snapceipt/Features/Auth/SignInView.swift` (the `PreviewAPIClient`)
- Modify `SnapceiptTests/Mocks/MockAPIClient.swift`
- Create `SnapceiptTests/SendQuoteResponseTests.swift`

**Steps**

1. Write the failing test `SnapceiptTests/SendQuoteResponseTests.swift` (mirrors `UpdateDevicePayloadTests`: a DTO-decode test + a Mock-records-the-call test):
   ```swift
   import Testing
   import Foundation
   @testable import Snapceipt

   @Suite("SendQuote response + mock")
   struct SendQuoteResponseTests {
       @Test("SendQuoteResponse decodes the camelCase send payload")
       func decode() throws {
           let json = """
           {"number":"SN-0001","sentAt":1717200000000,"status":"sent",
            "subtotalCents":40000,"gstCents":4000,"totalCents":44000,
            "pdfUrl":"/quotes/dl/tok","expiresAt":1717804800000,"emailed":true}
           """
           let r = try JSONDecoder().decode(SendQuoteResponse.self, from: Data(json.utf8))
           #expect(r.number == "SN-0001")
           #expect(r.sentAt == 1717200000000)
           #expect(r.status == "sent")
           #expect(r.subtotalCents == 40000)
           #expect(r.gstCents == 4000)
           #expect(r.totalCents == 44000)
           #expect(r.pdfUrl == "/quotes/dl/tok")
           #expect(r.expiresAt == 1717804800000)
           #expect(r.emailed == true)
       }

       @Test("SendQuoteResponse tolerates a null number/pdfUrl/expiresAt (email off)")
       func decodeNulls() throws {
           let json = """
           {"number":null,"sentAt":1,"status":"sent","subtotalCents":1,"gstCents":0,
            "totalCents":1,"pdfUrl":null,"expiresAt":null,"emailed":false}
           """
           let r = try JSONDecoder().decode(SendQuoteResponse.self, from: Data(json.utf8))
           #expect(r.number == nil)
           #expect(r.pdfUrl == nil)
           #expect(r.expiresAt == nil)
           #expect(r.emailed == false)
       }

       @Test("MockAPIClient records the sendQuote call and returns the scripted response")
       func mockRecords() async throws {
           let mock = MockAPIClient()
           mock.sendQuoteHandler = { _ in
               SendQuoteResponse(number: "SN-0007", sentAt: 5, status: "sent",
                                 subtotalCents: 100, gstCents: 10, totalCents: 110,
                                 pdfUrl: nil, expiresAt: nil, emailed: false)
           }
           let r = try await mock.sendQuote("q-1")
           #expect(mock.sendQuoteCalls == ["q-1"])
           #expect(r.number == "SN-0007")
           #expect(r.emailed == false)
       }
   }
   ```

2. Run it RED:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/SendQuoteResponseTests test
   ```

3. Implement across the five files.

   `Snapceipt/Sync/DTOs.swift` — add after the `UpdateDeviceResponse` struct (end of the device section):
   ```swift
   // MARK: - Quotes (spec §4.5)

   /// POST /quotes/:id/send response. `number`/`pdfUrl`/`expiresAt` are null when the
   /// quote had no number yet but email is off, or generally when not applicable; the
   /// editor applies number/status/sentAt/totals to the local Quote on success.
   struct SendQuoteResponse: Decodable {
       let number: String?
       let sentAt: Int?
       let status: String
       let subtotalCents: Int
       let gstCents: Int
       let totalCents: Int
       let pdfUrl: String?
       let expiresAt: Int?
       let emailed: Bool
   }
   ```

   `Snapceipt/Sync/APIClient.swift` — add to the `APIClient` protocol (after `updateDevice`):
   ```swift
       /// POST /quotes/:id/send — recompute totals, assign SN-#### (if unset), render the
       /// PDF, email the client; returns the applied number/status/sentAt/totals. (§4.5)
       func sendQuote(_ id: String) async throws -> SendQuoteResponse
   ```
   And the `LiveAPIClient` implementation (after `updateDevice`):
   ```swift
       func sendQuote(_ id: String) async throws -> SendQuoteResponse {
           try await send("POST", "/quotes/\(id)/send", body: NoBody(), authenticated: true)
       }
   ```

   `Snapceipt/Sync/StubAPIClient.swift` — add before the closing brace of `StubAPIClient` (deterministic stub; emailed false so the UI-test success path doesn't need a real link):
   ```swift
       func sendQuote(_ id: String) async throws -> SendQuoteResponse {
           SendQuoteResponse(number: "SN-0001", sentAt: 1_790_000_000_000, status: "sent",
                             subtotalCents: 40_000, gstCents: 4_000, totalCents: 44_000,
                             pdfUrl: "/quotes/dl/stub-token", expiresAt: 1_790_000_000_000, emailed: false)
       }
   ```

   `Snapceipt/Features/Auth/SignInView.swift` — add to `PreviewAPIClient` (after `updateDevice`):
   ```swift
       func sendQuote(_ id: String) async throws -> SendQuoteResponse {
           SendQuoteResponse(number: "SN-0001", sentAt: 1_790_000_000_000, status: "sent",
                             subtotalCents: 0, gstCents: 0, totalCents: 0,
                             pdfUrl: nil, expiresAt: nil, emailed: false)
       }
   ```

   `SnapceiptTests/Mocks/MockAPIClient.swift` — add the handler + recorded-calls array (near the other capture handlers) and the method (after `updateDevice`):
   ```swift
       var sendQuoteHandler: ((String) async throws -> SendQuoteResponse)?
       private(set) var sendQuoteCalls: [String] = []
   ```
   ```swift
       func sendQuote(_ id: String) async throws -> SendQuoteResponse {
           sendQuoteCalls.append(id)
           guard let h = sendQuoteHandler else { throw MockAPIClientError.unscripted }
           return try await h(id)
       }
   ```

4. Run it GREEN:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/SendQuoteResponseTests test
   ```

5. Commit:
   ```
   git add Snapceipt/Sync/DTOs.swift Snapceipt/Sync/APIClient.swift Snapceipt/Sync/StubAPIClient.swift Snapceipt/Features/Auth/SignInView.swift SnapceiptTests/Mocks/MockAPIClient.swift SnapceiptTests/SendQuoteResponseTests.swift
   git commit -m "F5: APIClient.sendQuote + SendQuoteResponse across all 4 conformers

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

**Expected suite count after this task:** `SnapceiptTests` = 293 + 3 = **296**.

---

## Task 6 — `ClientPickerViewModel`

**Files**
- Create `Snapceipt/Features/Quotes/ClientPickerViewModel.swift`
- Create `SnapceiptTests/ClientPickerViewModelTests.swift`

**Steps**

1. Write the failing test `SnapceiptTests/ClientPickerViewModelTests.swift` (the `MockSyncEngine` spy is defined in `SnapceiptTests/AddProfileViewModelTests.swift` and shared across the target):
   ```swift
   import Testing
   import Foundation
   import SwiftData
   @testable import Snapceipt

   @MainActor
   @Suite("ClientPickerViewModel")
   struct ClientPickerViewModelTests {
       private func makeFixture() throws -> (ModelContext, MockSyncEngine) {
           let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
           return (ModelContext(container), MockSyncEngine())
       }

       private func vm(_ ctx: ModelContext, _ sync: MockSyncEngine) -> ClientPickerViewModel {
           ClientPickerViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1")
       }

       @Test("reload returns only the active profile's non-deleted clients, name-sorted")
       func reloadScoped() throws {
           let (ctx, sync) = try makeFixture()
           ctx.insert(Client(userId: "u1", profileId: "p1", name: "Beta"))
           ctx.insert(Client(userId: "u1", profileId: "p1", name: "Acme"))
           ctx.insert(Client(userId: "u1", profileId: "p2", name: "Other"))   // excluded
           try ctx.save()
           let v = vm(ctx, sync)
           #expect(v.clients.count == 2)
           #expect(v.clients[0].name == "Acme")   // name asc
           #expect(v.clients[1].name == "Beta")
       }

       @Test("create inserts a client scoped to the active profile and enqueues upsert")
       func createEnqueues() throws {
           let (ctx, sync) = try makeFixture()
           let v = vm(ctx, sync)
           let c = v.create(name: "  New Co  ", email: " n@co.com ")
           #expect(c != nil)
           #expect(c?.name == "New Co")            // trimmed
           #expect(c?.email == "n@co.com")         // trimmed
           #expect(c?.profileId == "p1")
           #expect(v.clients.count == 1)
           #expect(sync.calls.count == 1)
           #expect(sync.calls[0].entityType == .client)
           #expect(sync.calls[0].op == "upsert")
       }

       @Test("create returns nil for a blank name (no insert, no enqueue)")
       func createBlankRejected() throws {
           let (ctx, sync) = try makeFixture()
           let v = vm(ctx, sync)
           let c = v.create(name: "   ", email: nil)
           #expect(c == nil)
           #expect(v.clients.isEmpty)
           #expect(sync.calls.isEmpty)
       }

       @Test("create normalizes an empty email to nil")
       func createEmptyEmail() throws {
           let (ctx, sync) = try makeFixture()
           let v = vm(ctx, sync)
           let c = v.create(name: "X", email: "   ")
           #expect(c?.email == nil)
       }

       @Test("filtered matches name + email, case-insensitive")
       func filtered() throws {
           let (ctx, sync) = try makeFixture()
           ctx.insert(Client(userId: "u1", profileId: "p1", name: "Acme Pty", email: "ap@acme.com"))
           ctx.insert(Client(userId: "u1", profileId: "p1", name: "Beta", email: "b@x.com"))
           try ctx.save()
           let v = vm(ctx, sync)
           #expect(v.filtered(search: "acme").count == 1)
           #expect(v.filtered(search: "B@X").count == 1)
           #expect(v.filtered(search: "  ").count == 2)   // blank -> all
       }
   }
   ```

2. Run it RED:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/ClientPickerViewModelTests test
   ```

3. Implement `Snapceipt/Features/Quotes/ClientPickerViewModel.swift` (mirrors `LoyaltyWalletViewModel` + `AddLoyaltyViewModel.save`):
   ```swift
   import Foundation
   import SwiftData
   import Observation

   /// Drives the bill-to client picker. Loads the active profile's saved clients
   /// (name-sorted), supports inline create (+ enqueue upsert). `@MainActor`; deps
   /// injected for tests.
   @Observable
   @MainActor
   final class ClientPickerViewModel {
       @ObservationIgnored private let context: ModelContext
       @ObservationIgnored private let sync: any SyncEnqueuing
       @ObservationIgnored private let userId: String
       @ObservationIgnored let profileId: String

       /// Active profile's live clients, name-sorted.
       private(set) var clients: [Client] = []

       init(context: ModelContext, sync: any SyncEnqueuing, userId: String, profileId: String) {
           self.context = context
           self.sync = sync
           self.userId = userId
           self.profileId = profileId
           reload()
       }

       func reload() {
           let pid = profileId
           let d = FetchDescriptor<Client>(
               predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil },
               sortBy: [SortDescriptor(\.name), SortDescriptor(\.createdAt)])
           clients = (try? context.fetch(d)) ?? []
       }

       /// Clients filtered by a case-insensitive name/email substring (blank -> all).
       func filtered(search: String) -> [Client] {
           let q = search.trimmingCharacters(in: .whitespaces).lowercased()
           guard !q.isEmpty else { return clients }
           return clients.filter {
               $0.name.lowercased().contains(q) || ($0.email?.lowercased().contains(q) ?? false)
           }
       }

       /// Create a client scoped to the active profile (+ enqueue an upsert). Trims
       /// name/email; an empty email becomes nil. Returns nil for a blank name.
       @discardableResult
       func create(name: String, email: String?) -> Client? {
           let trimmedName = name.trimmingCharacters(in: .whitespaces)
           guard !trimmedName.isEmpty else { return nil }
           let trimmedEmail = email?.trimmingCharacters(in: .whitespaces)
           let normalizedEmail = (trimmedEmail?.isEmpty ?? true) ? nil : trimmedEmail
           let client = Client(userId: userId, profileId: profileId,
                               name: trimmedName, email: normalizedEmail)
           context.insert(client)
           try? context.save()
           reload()
           sync.enqueue(op: "upsert", entityType: .client, entity: client)
           return client
       }
   }
   ```

4. Run it GREEN:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/ClientPickerViewModelTests test
   ```

5. Commit:
   ```
   git add Snapceipt/Features/Quotes/ClientPickerViewModel.swift SnapceiptTests/ClientPickerViewModelTests.swift
   git commit -m "F5: ClientPickerViewModel (profile-scoped clients + inline create)

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

**Expected suite count after this task:** `SnapceiptTests` = 296 + 5 = **301**.

---

## Task 7 — `QuoteListViewModel`

**Files**
- Create `Snapceipt/Features/Quotes/QuoteListViewModel.swift`
- Create `SnapceiptTests/QuoteListViewModelTests.swift`

**Steps**

1. Write the failing test `SnapceiptTests/QuoteListViewModelTests.swift`:
   ```swift
   import Testing
   import Foundation
   import SwiftData
   @testable import Snapceipt

   @MainActor
   @Suite("QuoteListViewModel")
   struct QuoteListViewModelTests {
       private func makeFixture() throws -> (ModelContext, MockSyncEngine) {
           let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
           return (ModelContext(container), MockSyncEngine())
       }

       private func vm(_ ctx: ModelContext, _ sync: MockSyncEngine) -> QuoteListViewModel {
           QuoteListViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1")
       }

       private func insertQuote(_ ctx: ModelContext, profileId: String, createdAt: Int,
                                clientName: String) {
           let q = Quote(userId: "u1", profileId: profileId, clientName: clientName,
                         createdAt: createdAt, updatedAt: createdAt)
           ctx.insert(q)
       }

       @Test("reload returns only the active profile's non-deleted quotes, newest first")
       func reloadScopedNewestFirst() throws {
           let (ctx, sync) = try makeFixture()
           insertQuote(ctx, profileId: "p1", createdAt: 100, clientName: "Old")
           insertQuote(ctx, profileId: "p1", createdAt: 300, clientName: "New")
           insertQuote(ctx, profileId: "p2", createdAt: 200, clientName: "Other")   // excluded
           try ctx.save()
           let v = vm(ctx, sync)
           #expect(v.quotes.count == 2)
           #expect(v.quotes[0].clientName == "New")   // createdAt desc
           #expect(v.quotes[1].clientName == "Old")
       }

       @Test("delete soft-deletes (excluded from reload) and enqueues a delete")
       func deleteSoft() throws {
           let (ctx, sync) = try makeFixture()
           insertQuote(ctx, profileId: "p1", createdAt: 100, clientName: "X")
           try ctx.save()
           let v = vm(ctx, sync)
           let q = v.quotes[0]
           v.delete(q)
           let live = try ctx.fetch(FetchDescriptor<Quote>(predicate: #Predicate { $0.deletedAt == nil }))
           #expect(live.isEmpty)
           #expect(v.quotes.isEmpty)
           #expect(sync.calls.last?.op == "delete")
           #expect(sync.calls.last?.entityType == .quote)
       }
   }
   ```

2. Run it RED:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/QuoteListViewModelTests test
   ```

3. Implement `Snapceipt/Features/Quotes/QuoteListViewModel.swift`:
   ```swift
   import Foundation
   import SwiftData
   import Observation

   /// Drives the quotes list. Loads the active profile's live quotes (newest first),
   /// soft-deletes through the sync seam. `@MainActor`; deps injected for tests.
   /// Mirrors LoyaltyWalletViewModel.
   @Observable
   @MainActor
   final class QuoteListViewModel {
       @ObservationIgnored private let context: ModelContext
       @ObservationIgnored private let sync: any SyncEnqueuing
       @ObservationIgnored private let userId: String
       @ObservationIgnored let profileId: String

       /// Active profile's live quotes, newest first.
       private(set) var quotes: [Quote] = []

       init(context: ModelContext, sync: any SyncEnqueuing, userId: String, profileId: String) {
           self.context = context
           self.sync = sync
           self.userId = userId
           self.profileId = profileId
           reload()
       }

       func reload() {
           let pid = profileId
           let d = FetchDescriptor<Quote>(
               predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil },
               sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
           quotes = (try? context.fetch(d)) ?? []
       }

       /// Soft-delete (set deletedAt) + enqueue a delete. (Line items tombstone with
       /// the quote server-side; the local rows are orphaned harmlessly.)
       func delete(_ quote: Quote) {
           quote.deletedAt = Epoch.nowMs()
           quote.updatedAt = Epoch.nowMs()
           try? context.save()
           reload()
           sync.enqueue(op: "delete", entityType: .quote, entity: quote)
       }
   }
   ```

4. Run it GREEN:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/QuoteListViewModelTests test
   ```

5. Commit:
   ```
   git add Snapceipt/Features/Quotes/QuoteListViewModel.swift SnapceiptTests/QuoteListViewModelTests.swift
   git commit -m "F5: QuoteListViewModel (profile-scoped newest-first + soft-delete)

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

**Expected suite count after this task:** `SnapceiptTests` = 301 + 2 = **303**.

---

## Task 8 — `QuoteEditorViewModel` (the meatiest)

**Files**
- Create `Snapceipt/Features/Quotes/QuoteEditorViewModel.swift`
- Create `SnapceiptTests/QuoteEditorViewModelTests.swift`

The editor VM owns: `load(id?)` (existing quote + its non-deleted line items, or a fresh draft); a working `[QuoteLineItem]` set; `gstEnabled`; the client snapshot (`clientName`/`clientEmail`); computed `totals` via `QuoteTotals`; `addLine()`/`removeLine(_:)`; `saveDraft()` (upsert the quote with recomputed totals + diff the line items vs the persisted rows → enqueue `upsert`/`delete` per item, `sortOrder` = index); `canSend` (a client name + ≥1 line item); and `send(api:)` (saveDraft → `api.sendQuote(id)` → apply `number`/`status`/`sentAt`/totals → save → enqueue the quote upsert).

**Steps**

1. Write the failing test `SnapceiptTests/QuoteEditorViewModelTests.swift`:
   ```swift
   import Testing
   import Foundation
   import SwiftData
   @testable import Snapceipt

   @MainActor
   @Suite("QuoteEditorViewModel")
   struct QuoteEditorViewModelTests {
       private func makeFixture() throws -> (ModelContext, MockSyncEngine) {
           let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
           return (ModelContext(container), MockSyncEngine())
       }

       private func vm(_ ctx: ModelContext, _ sync: MockSyncEngine) -> QuoteEditorViewModel {
           QuoteEditorViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1")
       }

       @Test("load(nil) starts a fresh draft: empty lines, gst on, no client, not sendable")
       func loadNew() throws {
           let (ctx, sync) = try makeFixture()
           let v = vm(ctx, sync)
           v.load(id: nil)
           #expect(v.lineItems.isEmpty)
           #expect(v.gstEnabled == true)
           #expect(v.clientName == nil)
           #expect(v.canSend == false)
           #expect(v.quoteId != nil)   // a draft id is minted on load
       }

       @Test("addLine then setting a client makes the quote sendable; totals compute")
       func addLineAndClient() throws {
           let (ctx, sync) = try makeFixture()
           let v = vm(ctx, sync)
           v.load(id: nil)
           v.addLine()
           v.lineItems[0].itemDescription = "Design"
           v.lineItems[0].quantity = 2
           v.lineItems[0].unitPriceCents = 100_00
           v.setClient(name: "Acme", email: "a@acme.com")
           #expect(v.canSend == true)
           #expect(v.totals.subtotal == 200_00)
           #expect(v.totals.gst == 20_00)
           #expect(v.totals.total == 220_00)
       }

       @Test("toggling GST off zeroes gst in totals")
       func gstOff() throws {
           let (ctx, sync) = try makeFixture()
           let v = vm(ctx, sync)
           v.load(id: nil)
           v.addLine()
           v.lineItems[0].unitPriceCents = 100_00
           v.gstEnabled = false
           #expect(v.totals.gst == 0)
           #expect(v.totals.total == 100_00)
       }

       @Test("saveDraft persists the quote (profileId set, totals stored) + enqueues quote upsert + per-line upserts")
       func saveDraftEnqueues() throws {
           let (ctx, sync) = try makeFixture()
           let v = vm(ctx, sync)
           v.load(id: nil)
           v.setClient(name: "Acme", email: "a@acme.com")
           v.addLine(); v.lineItems[0].itemDescription = "A"; v.lineItems[0].unitPriceCents = 50_00
           v.addLine(); v.lineItems[1].itemDescription = "B"; v.lineItems[1].unitPriceCents = 30_00
           v.saveDraft()

           let quotes = try ctx.fetch(FetchDescriptor<Quote>(predicate: #Predicate { $0.deletedAt == nil }))
           #expect(quotes.count == 1)
           #expect(quotes[0].profileId == "p1")
           #expect(quotes[0].clientName == "Acme")
           #expect(quotes[0].subtotalCents == 80_00)
           #expect(quotes[0].gstCents == 8_00)
           #expect(quotes[0].totalCents == 88_00)
           let lines = try ctx.fetch(FetchDescriptor<QuoteLineItem>(predicate: #Predicate { $0.deletedAt == nil }))
           #expect(lines.count == 2)
           #expect(lines.allSatisfy { $0.quoteId == quotes[0].id })
           // 1 quote upsert + 2 line upserts.
           #expect(sync.calls.filter { $0.entityType == .quote && $0.op == "upsert" }.count == 1)
           #expect(sync.calls.filter { $0.entityType == .quoteLineItem && $0.op == "upsert" }.count == 2)
       }

       @Test("saveDraft after removing a line soft-deletes it and enqueues a line delete")
       func saveDraftDiffDeletes() throws {
           let (ctx, sync) = try makeFixture()
           let v = vm(ctx, sync)
           v.load(id: nil)
           v.setClient(name: "Acme", email: nil)
           v.addLine(); v.lineItems[0].itemDescription = "A"; v.lineItems[0].unitPriceCents = 10_00
           v.addLine(); v.lineItems[1].itemDescription = "B"; v.lineItems[1].unitPriceCents = 20_00
           v.saveDraft()
           let id = v.quoteId!
           // Reopen, drop one line, save again.
           let v2 = vm(ctx, sync)
           v2.load(id: id)
           #expect(v2.lineItems.count == 2)
           v2.removeLine(v2.lineItems[0])
           v2.saveDraft()
           let live = try ctx.fetch(FetchDescriptor<QuoteLineItem>(predicate: #Predicate { $0.deletedAt == nil }))
           #expect(live.count == 1)
           #expect(sync.calls.contains { $0.entityType == .quoteLineItem && $0.op == "delete" })
       }

       @Test("load(id) reopens a saved quote with its lines + client + gst")
       func reload() throws {
           let (ctx, sync) = try makeFixture()
           let v = vm(ctx, sync)
           v.load(id: nil)
           v.setClient(name: "Beta", email: "b@x.com")
           v.gstEnabled = false
           v.addLine(); v.lineItems[0].itemDescription = "X"; v.lineItems[0].unitPriceCents = 15_00
           v.saveDraft()
           let id = v.quoteId!
           let v2 = vm(ctx, sync)
           v2.load(id: id)
           #expect(v2.clientName == "Beta")
           #expect(v2.gstEnabled == false)
           #expect(v2.lineItems.count == 1)
           #expect(v2.lineItems[0].itemDescription == "X")
       }

       @Test("send saves the draft, calls sendQuote once, and applies number/status/sentAt/totals")
       func sendApplies() async throws {
           let (ctx, sync) = try makeFixture()
           let mock = MockAPIClient()
           mock.sendQuoteHandler = { _ in
               SendQuoteResponse(number: "SN-0042", sentAt: 999, status: "sent",
                                 subtotalCents: 50_00, gstCents: 5_00, totalCents: 55_00,
                                 pdfUrl: "/quotes/dl/tok", expiresAt: 1, emailed: true)
           }
           let v = vm(ctx, sync)
           v.load(id: nil)
           v.setClient(name: "Acme", email: "a@acme.com")
           v.addLine(); v.lineItems[0].unitPriceCents = 50_00
           let ok = await v.send(api: mock)
           #expect(ok == true)
           #expect(mock.sendQuoteCalls.count == 1)
           #expect(mock.sendQuoteCalls[0] == v.quoteId)
           #expect(v.number == "SN-0042")
           #expect(v.statusValue == .sent)
           #expect(v.sentAt == 999)
           #expect(v.emailed == true)
           let q = try ctx.fetch(FetchDescriptor<Quote>(predicate: #Predicate { $0.deletedAt == nil }))[0]
           #expect(q.number == "SN-0042")
           #expect(q.status == "sent")
           #expect(q.totalCents == 55_00)
       }

       @Test("send returns false + sets errorMessage when the API throws; status stays draft")
       func sendFailureKeepsDraft() async throws {
           let (ctx, sync) = try makeFixture()
           let mock = MockAPIClient()
           mock.sendQuoteHandler = { _ in throw APIError(code: "X", message: "boom", status: 500) }
           let v = vm(ctx, sync)
           v.load(id: nil)
           v.setClient(name: "Acme", email: "a@acme.com")
           v.addLine(); v.lineItems[0].unitPriceCents = 10_00
           let ok = await v.send(api: mock)
           #expect(ok == false)
           #expect(v.errorMessage != nil)
           #expect(v.statusValue == .draft)
           #expect(v.number == nil)
       }
   }
   ```

2. Run it RED:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/QuoteEditorViewModelTests test
   ```

3. Implement `Snapceipt/Features/Quotes/QuoteEditorViewModel.swift`. The working line-item set holds **unsaved** `QuoteLineItem` instances bound directly to SwiftUI fields; `saveDraft()` inserts/updates the persisted `Quote` and diffs the working lines against the persisted rows.
   ```swift
   import Foundation
   import SwiftData
   import Observation

   /// Drives the quote editor. Owns a draft quote id, a working line-item set, the GST
   /// toggle, and the client snapshot; computes live totals via `QuoteTotals`; persists
   /// via `saveDraft()` (quote upsert + per-line diff/enqueue) and sends via the injected
   /// `APIClient`. `@MainActor`; deps injected for tests.
   @Observable
   @MainActor
   final class QuoteEditorViewModel {
       @ObservationIgnored private let context: ModelContext
       @ObservationIgnored private let sync: any SyncEnqueuing
       @ObservationIgnored private let userId: String
       @ObservationIgnored let profileId: String

       /// The persisted quote id (minted on `load(nil)`; the existing id on edit).
       private(set) var quoteId: String?
       /// The working (possibly unsaved) line items, in row order.
       var lineItems: [QuoteLineItem] = []
       var gstEnabled = true
       private(set) var clientName: String?
       private(set) var clientEmail: String?

       // Applied-on-send fields (mirrored from the response for the success overlay).
       private(set) var number: String?
       private(set) var status: String = QuoteStatus.draft.rawValue
       private(set) var sentAt: Int?
       private(set) var validUntil: String?
       private(set) var pdfUrl: String?
       private(set) var emailed = false

       /// In-flight + error state for the Send button.
       private(set) var isSending = false
       var errorMessage: String?

       /// The ids of line items that existed in the store when the editor opened — used
       /// by `saveDraft` to detect rows the user removed (diff -> enqueue delete).
       @ObservationIgnored private var originalLineIds: Set<String> = []

       init(context: ModelContext, sync: any SyncEnqueuing, userId: String, profileId: String) {
           self.context = context
           self.sync = sync
           self.userId = userId
           self.profileId = profileId
       }

       var statusValue: QuoteStatus? { QuoteStatus(rawValue: status) }

       /// Live totals from the working line items + the GST toggle.
       var totals: (subtotal: Int, gst: Int, total: Int) {
           QuoteTotals.compute(lineItems: lineItems, gstEnabled: gstEnabled)
       }

       /// Sendable once there is a client name AND at least one line item.
       var canSend: Bool {
           !(clientName ?? "").trimmingCharacters(in: .whitespaces).isEmpty && !lineItems.isEmpty
       }

       /// A draft display number ("SN-####" once sent, else "Draft").
       var displayNumber: String { number ?? "Draft" }

       /// Load an existing quote + its non-deleted lines, or mint a fresh draft (id only).
       func load(id: String?) {
           if let id, let q = fetchQuote(id) {
               quoteId = q.id
               gstEnabled = q.gstEnabled
               clientName = q.clientName
               clientEmail = q.clientEmail
               number = q.number
               status = q.status
               sentAt = q.sentAt
               validUntil = q.validUntil
               let qid = q.id
               let d = FetchDescriptor<QuoteLineItem>(
                   predicate: #Predicate { $0.quoteId == qid && $0.deletedAt == nil },
                   sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)])
               lineItems = (try? context.fetch(d)) ?? []
               originalLineIds = Set(lineItems.map(\.id))
           } else {
               quoteId = ID.uuidv7()
               gstEnabled = true
               clientName = nil
               clientEmail = nil
               number = nil
               status = QuoteStatus.draft.rawValue
               sentAt = nil
               validUntil = nil
               lineItems = []
               originalLineIds = []
           }
       }

       /// Snapshot a picked/created client onto the quote (copies name/email; no FK).
       func setClient(name: String, email: String?) {
           clientName = name
           clientEmail = email
       }

       /// Append a new blank working line (not persisted until `saveDraft`).
       func addLine() {
           guard let qid = quoteId else { return }
           lineItems.append(QuoteLineItem(userId: userId, quoteId: qid,
                                          itemDescription: "", quantity: 1, unitPriceCents: 0,
                                          sortOrder: lineItems.count))
       }

       /// Remove a working line (the diff in `saveDraft` enqueues a delete if it was saved).
       func removeLine(_ line: QuoteLineItem) {
           lineItems.removeAll { $0.id == line.id }
       }

       /// Upsert the quote (recomputed totals, profileId set) + diff the working lines vs
       /// the originally-loaded rows: upsert each kept line (sortOrder = index), soft-delete
       /// + enqueue-delete each removed one. Local-first; sync reconciles.
       func saveDraft() {
           guard let qid = quoteId else { return }
           let t = totals
           let quote = fetchQuote(qid) ?? {
               let q = Quote(userId: userId, profileId: profileId)
               q.id = qid
               context.insert(q)
               return q
           }()
           quote.profileId = profileId
           quote.clientName = clientName
           quote.clientEmail = clientEmail
           quote.gstEnabled = gstEnabled
           quote.subtotalCents = t.subtotal
           quote.gstCents = t.gst
           quote.totalCents = t.total
           quote.validUntil = validUntil
           quote.updatedAt = Epoch.nowMs()

           // Upsert kept lines (assign row-index sortOrder + persist if new).
           let keptIds = Set(lineItems.map(\.id))
           for (idx, line) in lineItems.enumerated() {
               line.sortOrder = idx
               line.updatedAt = Epoch.nowMs()
               if fetchLine(line.id) == nil { context.insert(line) }
           }
           // Soft-delete + enqueue-delete removed lines.
           let removed = originalLineIds.subtracting(keptIds)
           var deletedRows: [QuoteLineItem] = []
           for rid in removed {
               if let row = fetchLine(rid) {
                   row.deletedAt = Epoch.nowMs()
                   row.updatedAt = Epoch.nowMs()
                   deletedRows.append(row)
               }
           }
           try? context.save()

           sync.enqueue(op: "upsert", entityType: .quote, entity: quote)
           for line in lineItems { sync.enqueue(op: "upsert", entityType: .quoteLineItem, entity: line) }
           for row in deletedRows { sync.enqueue(op: "delete", entityType: .quoteLineItem, entity: row) }
           originalLineIds = keptIds
       }

       /// Save the draft, POST /quotes/:id/send, then apply number/status/sentAt/totals to
       /// the local quote + enqueue its upsert. Returns true on success; on failure sets
       /// `errorMessage` and the quote stays a draft (no number minted). `@MainActor`.
       func send(api: APIClient) async -> Bool {
           guard let qid = quoteId else { return false }
           errorMessage = nil
           saveDraft()
           isSending = true
           defer { isSending = false }
           do {
               let r = try await api.sendQuote(qid)
               number = r.number
               status = r.status
               sentAt = r.sentAt
               pdfUrl = r.pdfUrl
               emailed = r.emailed
               if let quote = fetchQuote(qid) {
                   quote.number = r.number
                   quote.status = r.status
                   quote.sentAt = r.sentAt
                   quote.subtotalCents = r.subtotalCents
                   quote.gstCents = r.gstCents
                   quote.totalCents = r.totalCents
                   quote.updatedAt = Epoch.nowMs()
                   try? context.save()
                   sync.enqueue(op: "upsert", entityType: .quote, entity: quote)
               }
               return true
           } catch let e as APIError {
               errorMessage = e.message
               return false
           } catch {
               errorMessage = "Couldn’t send the quote. Try again."
               return false
           }
       }

       // MARK: - Fetch helpers

       private func fetchQuote(_ id: String) -> Quote? {
           var d = FetchDescriptor<Quote>(predicate: #Predicate { $0.id == id })
           d.fetchLimit = 1
           return (try? context.fetch(d))?.first
       }

       private func fetchLine(_ id: String) -> QuoteLineItem? {
           var d = FetchDescriptor<QuoteLineItem>(predicate: #Predicate { $0.id == id })
           d.fetchLimit = 1
           return (try? context.fetch(d))?.first
       }
   }
   ```

4. Run it GREEN:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/QuoteEditorViewModelTests test
   ```

5. Commit:
   ```
   git add Snapceipt/Features/Quotes/QuoteEditorViewModel.swift SnapceiptTests/QuoteEditorViewModelTests.swift
   git commit -m "F5: QuoteEditorViewModel (load/save-draft diff + totals + send)

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

**Expected suite count after this task:** `SnapceiptTests` = 303 + 8 = **311**.

---

## Task 9 — AccessibilityID additions (§4.6 + `home.quick.quote`)

**Files**
- Modify `Snapceipt/Shared/AccessibilityID.swift`

This Task is wiring-only (no behavior); it is validated by the build + the later UI test. There is no separate unit test for static string constants.

**Steps**

1. Add the Quotes ids to `Snapceipt/Shared/AccessibilityID.swift` (append before the closing `}` of the `AccessibilityID` enum, after the Loyalty block):
   ```swift
       // Home quick action (F5)
       static let homeQuickQuote = "home.quick.quote"

       // Quotes (F5)
       static let quotesScreen = "quotes.screen"
       static let quoteRowPrefix = "quote.row."             // + quote.id
       static let quotesAdd = "quotes.add"
       static let quoteEditorScreen = "quote.editor.screen"
       static let quoteEditorClient = "quote.editor.client"
       static let quoteEditorAddLine = "quote.editor.addLine"
       static let quoteLineRowPrefix = "quote.line.row."    // + line.id
       static let quoteEditorGst = "quote.editor.gst"
       static let quoteEditorSend = "quote.editor.send"
       static let clientPickerScreen = "client.picker.screen"
       static let clientPickerAdd = "client.picker.add"
       static let clientRowPrefix = "client.row."           // + client.id
   ```

2. Build (no unit test — this is constant wiring):
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' build
   ```

3. Commit:
   ```
   git add Snapceipt/Shared/AccessibilityID.swift
   git commit -m "F5: AccessibilityID constants for Quotes (§4.6 + home.quick.quote)

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

**Expected suite count after this task:** unchanged (**311**); build green.

---

## Task 10 — Router cases + RootView keeps compiling (sheet exclusions)

**Files**
- Modify `Snapceipt/App/Router.swift`
- Modify `Snapceipt/App/RootView.swift`

This adds the two `Overlay` cases and threads them through the `sheetContent` EmptyView arm + both `sheetBinding` exclusion paths (the `Set` membership for non-associated ids + the `hasPrefix("quoteEditor")` guard for the associated-value case), exactly mirroring `.budgetEditor`. No new overlay rendering yet (Tasks 11/13 add the views; Task 14 wires the actual `.overlay`s) — this Task only keeps the project compiling with the new cases and is gated on a full build + the existing UI suite (the budgets/loyalty UI flow must stay green because it shares `sheetBinding`).

**Steps**

1. Add the cases + ids + a convenience opener to `Snapceipt/App/Router.swift`.

   In the `Overlay` enum, after `case loyaltyCard(id: String)`:
   ```swift
       case loyaltyCard(id: String)
       case quotes
       case quoteEditor(id: String?)   // nil id = create a new quote
   ```
   In the `id` switch, after the `.loyaltyCard` arm:
   ```swift
           case .loyaltyCard(let id): return "loyaltyCard-\(id)"
           case .quotes: return "quotes"
           case .quoteEditor(let id): return "quoteEditor-\(id ?? "new")"
   ```
   Add an opener near `openBudget(_:)`:
   ```swift
       /// Open the quote editor for `id` (nil = create a new quote).
       func openQuote(_ id: String?) { overlay = .quoteEditor(id: id) }
   ```

2. Thread the new cases through `Snapceipt/App/RootView.swift`'s sheet plumbing.

   In `sheetContent(for:)`, extend the trailing full-screen EmptyView arm to include the two new cases:
   ```swift
           case .mileage, .wfh, .budgets, .budgetEditor, .alerts, .notificationSettings,
                .loyalty, .loyaltyAdd, .loyaltyCard, .quotes, .quoteEditor:
               EmptyView()  // handled by the full-screen overlays
   ```

   In `sheetBinding`, extend the `get` exclusion switch:
   ```swift
               get: {
                   switch router.overlay {
                   case .capture, .mileage, .wfh, .budgets, .budgetEditor, .alerts, .notificationSettings,
                        .loyalty, .loyaltyAdd, .loyaltyCard, .quotes, .quoteEditor:
                       return nil
                   default: return router.overlay
                   }
               },
   ```
   And the `set` full-screen Set + the prefix guard (add `.quotes.id` to the Set, and `quoteEditor` to the `hasPrefix` checks):
   ```swift
               set: { newValue in
                   let fullScreen: Set<String> = [Overlay.capture.id, Overlay.mileage.id, Overlay.wfh.id,
                                                  Overlay.budgets.id, Overlay.alerts.id,
                                                  Overlay.notificationSettings.id,
                                                  Overlay.loyalty.id, Overlay.loyaltyAdd.id,
                                                  Overlay.quotes.id]
                   if newValue == nil, let cur = router.overlay,
                      !fullScreen.contains(cur.id),
                      !cur.id.hasPrefix("budgetEditor"), !cur.id.hasPrefix("loyaltyCard"),
                      !cur.id.hasPrefix("quoteEditor") {
                       router.dismissOverlay()
                   } else if let newValue {
                       router.overlay = newValue
                   }
               }
   ```

3. Build + run the existing UI suites that share `sheetBinding` (must stay green):
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' build
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptUITests/BudgetsUITests test
   ```

4. Commit:
   ```
   git add Snapceipt/App/Router.swift Snapceipt/App/RootView.swift
   git commit -m "F5: Router .quotes/.quoteEditor cases + RootView sheet exclusions

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

**Expected suite count after this task:** unchanged (**311**); build + `BudgetsUITests` green.

---

## Task 11 — `QuoteListView`

**Files**
- Create `Snapceipt/Features/Quotes/QuoteListView.swift`

A view with no unit test; gated on a full build (it is exercised end-to-end by `QuotesUITests` in Task 16). Mirrors `BudgetListView`/`LoyaltyWalletView` chrome.

**Steps**

1. Implement `Snapceipt/Features/Quotes/QuoteListView.swift`:
   ```swift
   import SwiftUI
   import SwiftData

   /// Full-screen quotes list: LbHeader, rows (client · total · status badge · date),
   /// EmptyArt, LbFloatingCTA "New quote". Tap a row -> editor; swipe -> soft-delete.
   struct QuoteListView: View {
       let context: ModelContext
       let sync: any SyncEnqueuing
       let userId: String
       let profileId: String
       let onClose: () -> Void
       let onEdit: (String?) -> Void   // nil = new quote

       @Environment(\.accent) private var accent
       @State private var vm: QuoteListViewModel?

       var body: some View {
           ZStack(alignment: .bottom) {
               Palette.cream.ignoresSafeArea()
               VStack(spacing: 0) {
                   LbHeader(title: "Quotes", onClose: onClose, onAdd: { onEdit(nil) })
                   if let vm {
                       if vm.quotes.isEmpty {
                           Spacer(); EmptyArt()
                           Text("No quotes yet").font(.ui(15)).foregroundStyle(Palette.ink3)
                               .padding(.top, 6)
                           Spacer()
                       } else {
                           List {
                               ForEach(vm.quotes) { quote in
                                   Button { onEdit(quote.id) } label: { rowBody(quote) }
                                       .buttonStyle(.plain)
                                       .accessibilityIdentifier(AccessibilityID.quoteRowPrefix + quote.id)
                                       .swipeActions {
                                           Button(role: .destructive) { vm.delete(quote) } label: { Text("Delete") }
                                       }
                               }
                               .listRowBackground(Palette.cream)
                           }
                           .listStyle(.plain)
                           .scrollContentBackground(.hidden)
                       }
                   } else { Color.clear }
               }
               LbFloatingCTA(title: "New quote", a11yId: AccessibilityID.quotesAdd) { onEdit(nil) }
           }
           .accessibilityElement(children: .contain)
           .accessibilityIdentifier(AccessibilityID.quotesScreen)
           .transition(.opacity)
           .task {
               vm = QuoteListViewModel(context: context, sync: sync, userId: userId, profileId: profileId)
           }
       }

       @ViewBuilder private func rowBody(_ quote: Quote) -> some View {
           HStack(spacing: 12) {
               VStack(alignment: .leading, spacing: 4) {
                   Text(quote.clientName ?? "No client").font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                   HStack(spacing: 6) {
                       Text(quote.number ?? "Draft").font(.ui(11.5, .semibold)).foregroundStyle(Palette.ink3)
                       statusBadge(quote)
                   }
               }
               Spacer()
               VStack(alignment: .trailing, spacing: 4) {
                   Text(fmt(quote.totalCents)).font(.ui(14, .semibold)).foregroundStyle(Palette.ink).monospacedDigit()
                   Text(fmtDate(isoDay(quote.createdAt))).font(.ui(11.5)).foregroundStyle(Palette.ink3)
               }
           }
           .padding(.vertical, 6)
       }

       @ViewBuilder private func statusBadge(_ quote: Quote) -> some View {
           let label = quote.statusValue?.label ?? "Draft"
           let isSent = quote.statusValue == .sent || quote.statusValue == .accepted || quote.statusValue == .invoiced
           Text(label).font(.ui(10.5, .bold)).foregroundStyle(isSent ? Palette.income : Palette.ink3)
               .padding(.vertical, 2).padding(.horizontal, 8)
               .background((isSent ? Palette.income : Palette.ink3).opacity(0.14), in: Capsule())
       }

       /// Convert an epoch-ms createdAt into a "yyyy-MM-dd" string for `fmtDate`.
       private func isoDay(_ ms: Int) -> String {
           ExportDateFormatter.shared.string(from: Date(timeIntervalSince1970: Double(ms) / 1000.0))
       }
   }
   ```

2. Build:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' build
   ```

3. Commit:
   ```
   git add Snapceipt/Features/Quotes/QuoteListView.swift
   git commit -m "F5: QuoteListView (LbHeader + rows + EmptyArt + New quote CTA)

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

**Expected suite count after this task:** unchanged (**311**); build green.

---

## Task 12 — `ClientPickerSheet`

**Files**
- Create `Snapceipt/Features/Quotes/ClientPickerSheet.swift`

A `.sheet`-presented picker local to the editor (not a router overlay). View with no unit test; gated on a full build (driven by `QuotesUITests`). The `onPick(name:email:)` callback hands the chosen/created client's snapshot back to the editor.

**Steps**

1. Implement `Snapceipt/Features/Quotes/ClientPickerSheet.swift`:
   ```swift
   import SwiftUI
   import SwiftData

   /// Bill-to client picker, presented as a `.sheet` from the editor. Lists the active
   /// profile's saved clients (searchable), plus an inline "New client" form. Picking or
   /// creating a client hands its name/email snapshot back via `onPick`.
   struct ClientPickerSheet: View {
       let context: ModelContext
       let sync: any SyncEnqueuing
       let userId: String
       let profileId: String
       let onPick: (_ name: String, _ email: String?) -> Void
       let onClose: () -> Void

       @Environment(\.accent) private var accent
       @State private var vm: ClientPickerViewModel?
       @State private var search = ""
       @State private var showNew = false
       @State private var newName = ""
       @State private var newEmail = ""

       var body: some View {
           VStack(spacing: 0) {
               SheetHeader(title: "Bill to", onClose: onClose)
               if let vm {
                   ScrollView {
                       VStack(alignment: .leading, spacing: 12) {
                           searchField
                           newClientButton
                           if showNew { newClientForm(vm) }
                           ForEach(vm.filtered(search: search)) { client in
                               Button { onPick(client.name, client.email) } label: { row(client) }
                                   .buttonStyle(.plain)
                                   .accessibilityIdentifier(AccessibilityID.clientRowPrefix + client.id)
                           }
                       }
                       .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 40)
                   }
               } else { Color.clear }
           }
           .frame(maxHeight: .infinity, alignment: .top)
           .background(Palette.cream)
           .accessibilityElement(children: .contain)
           .accessibilityIdentifier(AccessibilityID.clientPickerScreen)
           .task {
               if vm == nil {
                   vm = ClientPickerViewModel(context: context, sync: sync, userId: userId, profileId: profileId)
               }
           }
       }

       private var searchField: some View {
           TextField("Search clients", text: $search)
               .padding(12).background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
       }

       private var newClientButton: some View {
           Button { withAnimation { showNew.toggle() } } label: {
               HStack(spacing: 8) {
                   Icon(name: "plus", size: 16, color: accent.base, lineWidth: 2)
                   Text("New client").font(.ui(14.5, .semibold)).foregroundStyle(accent.base)
                   Spacer()
               }
               .padding(12)
               .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
               .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(accent.base.opacity(0.4), lineWidth: 1))
           }
           .buttonStyle(.plain)
           .accessibilityIdentifier(AccessibilityID.clientPickerAdd)
       }

       @ViewBuilder private func newClientForm(_ vm: ClientPickerViewModel) -> some View {
           VStack(alignment: .leading, spacing: 8) {
               field("Client name", text: $newName)
               field("Email (optional)", text: $newEmail)
               Button {
                   if let c = vm.create(name: newName, email: newEmail) {
                       onPick(c.name, c.email)
                   }
               } label: {
                   Text("Save client").font(.ui(15, .semibold)).foregroundStyle(.white)
                       .frame(maxWidth: .infinity, minHeight: 46)
                       .background(newName.trimmingCharacters(in: .whitespaces).isEmpty ? Palette.ink3 : accent.base,
                                   in: RoundedRectangle(cornerRadius: 14, style: .continuous))
               }
               .buttonStyle(.plain)
               .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
           }
           .padding(12)
           .background(Palette.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
       }

       private func field(_ title: String, text: Binding<String>) -> some View {
           VStack(alignment: .leading, spacing: 4) {
               Text(title).font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
               TextField(title, text: text)
                   .padding(12).background(Palette.cream, in: RoundedRectangle(cornerRadius: 12))
           }
       }

       private func row(_ client: Client) -> some View {
           HStack(spacing: 12) {
               IconCircle(name: "building", tint: accent.base, soft: accent.soft, size: 38, iconSize: 18)
               VStack(alignment: .leading, spacing: 2) {
                   Text(client.name).font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                   if let email = client.email {
                       Text(email).font(.ui(12)).foregroundStyle(Palette.ink3)
                   }
               }
               Spacer()
               Icon(name: "chevD", size: 14, color: Palette.ink3)
           }
           .padding(.vertical, 6)
       }
   }
   ```

2. Build:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' build
   ```

3. Commit:
   ```
   git add Snapceipt/Features/Quotes/ClientPickerSheet.swift
   git commit -m "F5: ClientPickerSheet (saved clients + search + inline new client)

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

**Expected suite count after this task:** unchanged (**311**); build green.

---

## Task 13 — `QuoteEditorView`

**Files**
- Create `Snapceipt/Features/Quotes/QuoteEditorView.swift`

The editor screen: `SheetHeader` + an `SN-####`/Draft badge; a bill-to card that opens `ClientPickerSheet`; inline line-item rows (description + qty + unit price, with add/remove); the GST toggle; a live totals card; a validity note; and a Send button with in-flight + error states and a success overlay that degrades to "View PDF" (via `ActivityView`) when `emailed:false`. View with no unit test; gated on a full build (driven by `QuotesUITests`).

> Reuse note: `ActivityView` is `private` to `ExportSheet.swift`, so this file declares its own small `QuoteActivityView` `UIViewControllerRepresentable` (same shape) for the optional "View PDF" share — no cross-file dependency.

**Steps**

1. Implement `Snapceipt/Features/Quotes/QuoteEditorView.swift`:
   ```swift
   import SwiftUI
   import SwiftData

   /// Full-screen quote editor. Bill-to client (-> ClientPickerSheet), inline line items,
   /// a GST toggle, live totals, and Send (-> APIClient.sendQuote). On success shows a
   /// success overlay; when email is off it offers "View PDF" via a share sheet.
   struct QuoteEditorView: View {
       let context: ModelContext
       let sync: any SyncEnqueuing
       let api: APIClient
       let userId: String
       let profileId: String
       let quoteId: String?          // nil = new
       let onClose: () -> Void

       @Environment(\.accent) private var accent
       @State private var vm: QuoteEditorViewModel?
       @State private var showClientPicker = false
       @State private var sent = false
       @State private var shareURL: URL?

       var body: some View {
           ZStack(alignment: .bottom) {
               Palette.cream.ignoresSafeArea()
               VStack(spacing: 0) {
                   SheetHeader(title: quoteId == nil ? "New quote" : "Quote", onClose: onClose)
                   if let vm { content(vm) } else { Color.clear }
               }
               if let vm { sendBar(vm) }
               if sent, let vm { successOverlay(vm) }
           }
           .accessibilityElement(children: .contain)
           .accessibilityIdentifier(AccessibilityID.quoteEditorScreen)
           .transition(.opacity)
           .task {
               if vm == nil {
                   let model = QuoteEditorViewModel(context: context, sync: sync,
                                                    userId: userId, profileId: profileId)
                   model.load(id: quoteId)
                   vm = model
               }
           }
           .sheet(isPresented: $showClientPicker) {
               if let vm {
                   ClientPickerSheet(context: context, sync: sync, userId: userId, profileId: profileId,
                                     onPick: { name, email in
                                         vm.setClient(name: name, email: email)
                                         showClientPicker = false
                                     },
                                     onClose: { showClientPicker = false })
                       .environment(\.accent, accent)
               }
           }
           .sheet(item: shareItem) { item in QuoteActivityView(url: item.url) }
       }

       @ViewBuilder private func content(_ vm: QuoteEditorViewModel) -> some View {
           ScrollView {
               VStack(alignment: .leading, spacing: 16) {
                   numberBadge(vm)
                   billToCard(vm)
                   lineItemsSection(vm)
                   gstRow(vm)
                   totalsCard(vm)
                   Text("Valid for 14 days. Accepted quotes convert to an invoice.")
                       .font(.ui(11.5)).foregroundStyle(Palette.ink3)
               }
               .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 120)
           }
       }

       private func numberBadge(_ vm: QuoteEditorViewModel) -> some View {
           HStack {
               Text(vm.displayNumber).font(.ui(13, .bold)).foregroundStyle(accent.base)
                   .padding(.vertical, 5).padding(.horizontal, 12)
                   .background(accent.soft, in: Capsule())
               Spacer()
           }
       }

       @ViewBuilder private func billToCard(_ vm: QuoteEditorViewModel) -> some View {
           Button { showClientPicker = true } label: {
               HStack(spacing: 12) {
                   IconCircle(name: "building", tint: accent.base, soft: accent.soft, size: 40, iconSize: 19)
                   VStack(alignment: .leading, spacing: 2) {
                       Text(vm.clientName ?? "Choose a client").font(.ui(14.5, .semibold))
                           .foregroundStyle(vm.clientName == nil ? Palette.ink3 : Palette.ink)
                       if let email = vm.clientEmail {
                           Text(email).font(.ui(12)).foregroundStyle(Palette.ink3)
                       }
                   }
                   Spacer()
                   Icon(name: "chevD", size: 14, color: Palette.ink3)
               }
               .padding(12)
               .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
               .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                   .strokeBorder(Palette.line2, lineWidth: 1))
           }
           .buttonStyle(.plain)
           .accessibilityIdentifier(AccessibilityID.quoteEditorClient)
       }

       @ViewBuilder private func lineItemsSection(_ vm: QuoteEditorViewModel) -> some View {
           VStack(alignment: .leading, spacing: 10) {
               Text("Line items").font(.ui(12.5, .bold)).foregroundStyle(Palette.ink3)
               ForEach(vm.lineItems) { line in
                   lineRow(vm, line)
                       .accessibilityIdentifier(AccessibilityID.quoteLineRowPrefix + line.id)
               }
               Button { vm.addLine() } label: {
                   HStack(spacing: 8) {
                       Icon(name: "plus", size: 16, color: accent.base, lineWidth: 2)
                       Text("Add line item").font(.ui(14.5, .semibold)).foregroundStyle(accent.base)
                       Spacer()
                   }
                   .padding(12)
                   .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
                   .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(accent.base.opacity(0.4), lineWidth: 1))
               }
               .buttonStyle(.plain)
               .accessibilityIdentifier(AccessibilityID.quoteEditorAddLine)
           }
       }

       private func lineRow(_ vm: QuoteEditorViewModel, _ line: QuoteLineItem) -> some View {
           VStack(spacing: 8) {
               TextField("Description", text: Binding(
                   get: { line.itemDescription }, set: { line.itemDescription = $0 }))
                   .padding(10).background(Palette.cream, in: RoundedRectangle(cornerRadius: 10))
               HStack(spacing: 8) {
                   TextField("Qty", text: Binding(
                       get: { String(line.quantity) },
                       set: { line.quantity = max(1, Int($0.filter(\.isNumber)) ?? 1) }))
                       .keyboardType(.numberPad)
                       .padding(10).frame(width: 70).background(Palette.cream, in: RoundedRectangle(cornerRadius: 10))
                   TextField("Unit $", text: Binding(
                       get: { String(line.unitPriceCents / 100) },
                       set: { line.unitPriceCents = (Int($0.filter(\.isNumber)) ?? 0) * 100 }))
                       .keyboardType(.numberPad)
                       .padding(10).background(Palette.cream, in: RoundedRectangle(cornerRadius: 10))
                   Text(fmt(line.lineTotalCents)).font(.ui(13, .semibold)).foregroundStyle(Palette.ink2).monospacedDigit()
                   Button { vm.removeLine(line) } label: {
                       Icon(name: "close", size: 16, color: Palette.ink3)
                   }.buttonStyle(.plain)
               }
           }
           .padding(12)
           .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
       }

       private func gstRow(_ vm: QuoteEditorViewModel) -> some View {
           Toggle(isOn: Binding(get: { vm.gstEnabled }, set: { vm.gstEnabled = $0 })) {
               Text("Add GST (10%)").font(.ui(14, .semibold)).foregroundStyle(Palette.ink)
           }
           .tint(accent.base)
           .padding(12)
           .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
           .accessibilityIdentifier(AccessibilityID.quoteEditorGst)
       }

       private func totalsCard(_ vm: QuoteEditorViewModel) -> some View {
           let t = vm.totals
           return VStack(spacing: 8) {
               totalRow("Subtotal", fmt(t.subtotal), bold: false)
               if vm.gstEnabled { totalRow("GST (10%)", fmt(t.gst), bold: false) }
               Divider()
               totalRow("Total", fmt(t.total), bold: true)
           }
           .padding(14)
           .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
       }

       private func totalRow(_ label: String, _ value: String, bold: Bool) -> some View {
           HStack {
               Text(label).font(.ui(bold ? 15 : 13.5, bold ? .bold : .regular)).foregroundStyle(Palette.ink2)
               Spacer()
               Text(value).font(.ui(bold ? 16 : 14, .semibold)).foregroundStyle(Palette.ink).monospacedDigit()
           }
       }

       @ViewBuilder private func sendBar(_ vm: QuoteEditorViewModel) -> some View {
           VStack(spacing: 6) {
               if let err = vm.errorMessage {
                   Text(err).font(.ui(12.5)).foregroundStyle(Palette.alert)
               }
               Button {
                   Task {
                       if await vm.send(api: api) {
                           withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { sent = true }
                       }
                   }
               } label: {
                   HStack(spacing: 8) {
                       if vm.isSending { ProgressView().tint(.white) }
                       Text(vm.isSending ? "Sending…" : "Send quote").font(.ui(16, .semibold)).foregroundStyle(.white)
                   }
                   .frame(maxWidth: .infinity, minHeight: 52)
                   .background(vm.canSend ? accent.base : Palette.ink3,
                               in: RoundedRectangle(cornerRadius: 16, style: .continuous))
               }
               .buttonStyle(.plain)
               .disabled(!vm.canSend || vm.isSending)
               .accessibilityIdentifier(AccessibilityID.quoteEditorSend)
           }
           .padding(.horizontal, 18).padding(.bottom, 26)
       }

       private func successOverlay(_ vm: QuoteEditorViewModel) -> some View {
           ZStack {
               Palette.cream.opacity(0.97).ignoresSafeArea()
               VStack(spacing: 14) {
                   ZStack {
                       Circle().fill(Palette.income).frame(width: 72, height: 72)
                       Icon(name: "check", size: 34, color: .white, lineWidth: 3)
                   }
                   Text(vm.emailed ? "Quote sent!" : "Quote ready!").font(.display(20, .bold)).foregroundStyle(Palette.ink)
                   Text("\(vm.displayNumber) · \(fmt(vm.totals.total))").font(.ui(14)).foregroundStyle(Palette.ink2)
                   if !vm.emailed, vm.pdfUrl != nil {
                       Button { openPDF(vm) } label: {
                           Text("View PDF").font(.ui(15, .semibold)).foregroundStyle(.white)
                               .frame(minWidth: 160, minHeight: 46)
                               .background(accent.base, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                       }.buttonStyle(.plain)
                   }
                   Button { onClose() } label: {
                       Text("Done").font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
                           .frame(minWidth: 160, minHeight: 46)
                           .background(Palette.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                           .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line, lineWidth: 1))
                   }.buttonStyle(.plain)
               }
           }
           .transition(.opacity)
       }

       private func openPDF(_ vm: QuoteEditorViewModel) {
           guard let url = vm.pdfUrl else { return }
           let full = url.hasPrefix("http") ? url : "https://api.snapceipt.app\(url)"
           shareURL = URL(string: full)
       }

       private struct ShareItem: Identifiable { let id = UUID(); let url: URL }
       private var shareItem: Binding<ShareItem?> {
           Binding(get: { shareURL.map { ShareItem(url: $0) } },
                   set: { if $0 == nil { shareURL = nil } })
       }
   }

   /// UIActivityViewController bridge for the optional "View PDF" share.
   private struct QuoteActivityView: UIViewControllerRepresentable {
       let url: URL
       func makeUIViewController(context: Context) -> UIActivityViewController {
           UIActivityViewController(activityItems: [url], applicationActivities: nil)
       }
       func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
   }
   ```

2. Build:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' build
   ```

3. Commit:
   ```
   git add Snapceipt/Features/Quotes/QuoteEditorView.swift
   git commit -m "F5: QuoteEditorView (bill-to, line items, GST, totals, Send + success)

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

**Expected suite count after this task:** unchanged (**311**); build green.

---

## Task 14 — RootView wiring: Business-only quick action + render the overlays

**Files**
- Modify `Snapceipt/App/RootView.swift`

Add the Business-only Home "Create Quote" quick action (gated on the active profile type) and render the `.quotes` + `.quoteEditor` full-screen overlays. The editor overlay passes the shell's `captureAPI` (the live/stub `APIClient`) so the UI test's stub drives Send.

**Steps**

1. In `homeStub(accent:)`, add a Business-only quick-action row after the existing Loyalty row (the `HStack` ending with `.padding(.top, 12)` that hosts `homeQuickLoyalty`):
   ```swift
                   HStack(spacing: 12) {
                       quickAction(title: "Loyalty Card", icon: "star", id: AccessibilityID.homeQuickLoyalty,
                                   accent: accent) { router.present(.loyalty) }
                   }
                   .padding(.horizontal, 18).padding(.top, 12)

                   // BUSINESS-ONLY: the Quotes feature is gated on the active profile type.
                   if profiles.activeProfile?.type == ProfileType.business.rawValue {
                       HStack(spacing: 12) {
                           quickAction(title: "Create Quote", icon: "receipt", id: AccessibilityID.homeQuickQuote,
                                       accent: accent) { router.present(.quotes) }
                       }
                       .padding(.horizontal, 18).padding(.top, 12)
                   }
   ```

   > `Profile.type` is the raw String (`"personal"`/`"business"`); compare against `ProfileType.business.rawValue` (verified in `ProfilesStore.swift` — `ProfileType: String { personal, business }`). `profiles.activeProfile` is the live active `Profile?` (verified property on `ProfilesStore`).
   > **Icon glyph (verified against `Snapceipt/DesignSystem/Icons.swift`):** there is NO `"doc"` glyph — the catalog keys are exactly `arrowLeft, arrowRight, bell, building, car, chart, check, chevD, chevR, clock, close, gear, home, info, pin, plus, receipt, sparkles, star, user, wallet, wfh`. An unknown name resolves to `Icons.paths[name] ?? ""` and renders a SILENT BLANK shape (no crash, no glyph) — so `"doc"` would ship an invisible tile icon. Use `"receipt"` (the document-shaped glyph, confirmed present); the `home.quick.quote` accessibility id is unchanged.

2. Render the two overlays. Add two `.overlay` blocks in `ShellView.body` after the `.loyaltyCard` overlay block (before `.toastHost(toasts)`):
   ```swift
           .overlay {
               if router.overlay == .quotes {
                   QuoteListView(context: profiles.context, sync: sync, userId: profiles.userId,
                                 profileId: profiles.activeProfileId,
                                 onClose: { router.dismissOverlay() },
                                 onEdit: { router.openQuote($0) })
                       .environment(\.accent, accent).transition(.opacity)
               }
           }
           .overlay {
               if case let .quoteEditor(id) = router.overlay {
                   QuoteEditorView(context: profiles.context, sync: sync, api: captureAPI,
                                   userId: profiles.userId, profileId: profiles.activeProfileId,
                                   quoteId: id,
                                   onClose: { router.dismissOverlay() })
                       .environment(\.accent, accent).transition(.opacity)
               }
           }
   ```

3. Build + run the regression UI suites that exercise the Home shell + sheet plumbing (must stay green — `shell.home`/`profile.switcher` still resolve, budgets/loyalty flows unaffected):
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' build
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptUITests/BudgetsUITests test
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptUITests/LoyaltyUITests test
   ```

4. Commit:
   ```
   git add Snapceipt/App/RootView.swift
   git commit -m "F5: Business-only Create Quote action + render .quotes/.quoteEditor

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

**Expected suite count after this task:** unchanged (**311**); build + `BudgetsUITests` + `LoyaltyUITests` green.

---

## Task 15 — Seed a Client + a Quote (+ line item) on the active business profile

**Files**
- Modify `Snapceipt/App/AppLaunch.swift`

The seeded business profile is `p1` (`type: "business"`, active under `-uiTestSeed`). Seed one `Client` + one draft `Quote` with one `QuoteLineItem` so `QuotesUITests` finds a pickable client + the list renders a row.

**Steps**

1. In `applySeedIfNeeded(authStore:context:)`, add the seed inserts before the final `try? context.save()` (after the loyalty-card seeds):
   ```swift
           // F5: seed a saved client + a draft quote (+ one line item) on p1 (active business).
           let client = Client(userId: DevAccount.userId, profileId: p1.id,
                               name: "Acme Pty Ltd", email: "accounts@acme.example")
           context.insert(client)
           let quote = Quote(userId: DevAccount.userId, profileId: p1.id,
                             clientName: "Northbridge Cafe", clientEmail: "owner@northbridge.example",
                             gstEnabled: true, subtotalCents: 200_00, gstCents: 20_00, totalCents: 220_00,
                             status: "draft")
           context.insert(quote)
           context.insert(QuoteLineItem(userId: DevAccount.userId, quoteId: quote.id,
                                        itemDescription: "Brand identity package", quantity: 1,
                                        unitPriceCents: 200_00, sortOrder: 0))
   ```

2. Build (the seed is exercised by `QuotesUITests` in Task 16; no unit assertion here):
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' build
   ```

3. Commit:
   ```
   git add Snapceipt/App/AppLaunch.swift
   git commit -m "F5: seed a Client + a Quote (+ line item) on the business profile

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

**Expected suite count after this task:** unchanged (**311**); build green.

---

## Task 16 — Hermetic `QuotesUITests`

**Files**
- Create `SnapceiptUITests/QuotesUITests.swift`

Drives the full flow on the seeded shell + stub API (no network): Home Create Quote (Business-only) → list → new editor → pick the seeded client → add a line item → toggle GST → Send (the `StubAPIClient.sendQuote` returns `emailed:false` + a deterministic number) → success → Done → **Home** (single-slot overlays: the editor replaced the list, so Done → `dismissOverlay()` lands on Home, NOT the list — verified against BudgetsUITests' documented model). Uses `app.descendants(matching: .any)[id]` for `.contain` screen ids and drives keyboard-dismiss by tapping always-on-screen chrome (the F4/F3 pattern).

**Steps**

1. Write `SnapceiptUITests/QuotesUITests.swift`:
   ```swift
   import XCTest

   /// Hermetic quotes flow: seeded shell + stub API (no network). Home Create Quote
   /// (Business-only) -> list -> new editor -> pick the seeded client -> add a line
   /// item -> toggle GST -> Send (stub) -> success overlay -> Done -> Home.
   /// Real PDF/email is covered by the backend tests + manual QA.
   final class QuotesUITests: UITestCase {
       func testCreateQuotePickClientAddLineSend() {
           launchSeeded()   // signed-in, business profile p1 active, seeded client + quote

           // Home Create Quote quick action (Business-only) -> quotes list.
           let quick = app.buttons[AccessibilityID.homeQuickQuote].firstMatch
           XCTAssertTrue(quick.waitForExistence(timeout: 10), "Create Quote quick action missing on Home (business profile)")
           quick.tap()
           XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.quotesScreen].waitForExistence(timeout: 5),
                         "Quotes list did not appear")

           // The seeded quote renders >=1 row.
           let seededRow = app.descendants(matching: .any).matching(NSPredicate(
               format: "identifier BEGINSWITH %@", AccessibilityID.quoteRowPrefix)).firstMatch
           XCTAssertTrue(seededRow.waitForExistence(timeout: 5), "No seeded quote row rendered")

           // New quote via the floating CTA -> editor.
           app.buttons[AccessibilityID.quotesAdd].firstMatch.tap()
           XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.quoteEditorScreen].waitForExistence(timeout: 5),
                         "Quote editor did not appear")

           // Open the bill-to picker -> pick the seeded client.
           app.buttons[AccessibilityID.quoteEditorClient].firstMatch.tap()
           XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.clientPickerScreen].waitForExistence(timeout: 5),
                         "Client picker did not appear")
           let clientRow = app.descendants(matching: .any).matching(NSPredicate(
               format: "identifier BEGINSWITH %@", AccessibilityID.clientRowPrefix)).firstMatch
           XCTAssertTrue(clientRow.waitForExistence(timeout: 5), "No seeded client row in the picker")
           clientRow.tap()
           // Back on the editor.
           XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.quoteEditorScreen].waitForExistence(timeout: 5),
                         "Did not return to the editor after picking a client")

           // Add a line item.
           app.buttons[AccessibilityID.quoteEditorAddLine].firstMatch.tap()
           let lineRow = app.descendants(matching: .any).matching(NSPredicate(
               format: "identifier BEGINSWITH %@", AccessibilityID.quoteLineRowPrefix)).firstMatch
           XCTAssertTrue(lineRow.waitForExistence(timeout: 5), "Line item row did not appear after Add")

           // Toggle GST (its container carries the id).
           let gst = app.switches[AccessibilityID.quoteEditorGst].firstMatch
           if gst.waitForExistence(timeout: 3) { gst.tap() }
           // Dismiss any keyboard from line-item editing by tapping the always-on-screen title.
           app.staticTexts["New quote"].firstMatch.tap()

           // Send -> success overlay (stub returns SN-0001, emailed:false).
           let send = app.buttons[AccessibilityID.quoteEditorSend]
           XCTAssertTrue(send.waitForExistence(timeout: 5), "Send button missing")
           XCTAssertTrue(send.isEnabled, "Send should be enabled with a client + a line item")
           send.tap()
           // Success copy ("Quote ready!" when emailed:false) appears.
           XCTAssertTrue(app.staticTexts["Quote ready!"].firstMatch.waitForExistence(timeout: 8)
                         || app.staticTexts["Quote sent!"].firstMatch.waitForExistence(timeout: 2),
                         "Success overlay did not appear after Send")

           // OVERLAY MODEL: `.quotes` and `.quoteEditor` are MUTUALLY-EXCLUSIVE router
           // overlays (one `router.overlay` at a time), so opening the editor REPLACED the
           // list, and "Done" -> `onClose()` -> `router.dismissOverlay()` lands back on
           // HOME, NOT the list (mirrors BudgetsUITests' documented behavior). Assert we
           // returned to Home and the Business-only Create Quote action is visible again.
           app.buttons["Done"].firstMatch.tap()
           XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.shellHome].waitForExistence(timeout: 5),
                         "Did not return to Home after Done")
           XCTAssertTrue(app.buttons[AccessibilityID.homeQuickQuote].firstMatch.waitForExistence(timeout: 5),
                         "Create Quote action missing on Home after returning")
       }
   }
   ```

2. Run it RED (if any wiring from Tasks 10–15 is wrong it fails; with everything correct it may pass first run):
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptUITests/QuotesUITests test
   ```
   If it fails, debug with `superpowers:systematic-debugging` (do NOT weaken assertions). Common gotchas: the keyboard covering Send (tap a neutral always-on static text like "New quote" to dismiss before tapping Send); a11y-container child resolution (always use `app.descendants(matching: .any)[id]` for screen ids); the `.sheet`-presented `ClientPickerSheet` — assert on its `client.picker.screen` container via `descendants(matching:.any)`, not the top-level query.

3. Run it GREEN:
   ```
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptUITests/QuotesUITests test
   ```

4. Commit:
   ```
   git add SnapceiptUITests/QuotesUITests.swift
   git commit -m "F5: hermetic QuotesUITests (create -> pick client -> line -> Send)

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

**Expected suite counts after this task:** `SnapceiptUITests` = 10 + 1 = **11** (1 LiveSmoke skip).

---

## Task 17 — Full-suite green gate

**Files**
- None (verification only).

**Steps**

1. Regenerate + run both full suites:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests test
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptUITests test
   ```
2. Confirm totals:
   - `SnapceiptTests` = **311** (279 baseline + 3 `ClientModelTests` Task 1 + 2 `ClientModelTests` Task 2 = 5 in `ClientModelTests` + 4 `QuoteStatusTests` + 5 `QuoteTotalsTests` + 3 `SendQuoteResponseTests` + 5 `ClientPickerViewModelTests` + 2 `QuoteListViewModelTests` + 8 `QuoteEditorViewModelTests` = 279 + 32 = 311). The Task 1 edits to `EntityTypeTests` (count 14→15 + add `"client"`) and `SwiftDataModelTests` (count 14→15) MODIFY existing tests — they add **zero** net tests, so 311 holds. If either still asserts 14, it is RED — fix it (do not weaken; the correct count is 15).
   - `SnapceiptUITests` = **11** (10 baseline + `QuotesUITests`, with the 1 LiveSmoke skip).
3. If any suite is red, fix the implementation (use `superpowers:systematic-debugging`); do not weaken assertions.
4. No new commit needed unless a fix was applied; if so, commit it with the standard trailer.

**Expected final suite counts:** `SnapceiptTests` **311**, `SnapceiptUITests` **11** (1 skip).

---

## Correctness reminders baked into this plan

- **Business-only entry.** The Home "Create Quote" quick action renders only when `profiles.activeProfile?.type == ProfileType.business.rawValue` (Task 14). A Personal profile never sees it and cannot reach `.quotes`/`.quoteEditor`. The accent/mode is read exactly the way the rest of `homeStub` reads it (`profiles.activeProfile`, `profiles.activeProfileId`).
- **profileId is always set on create.** `ClientPickerViewModel.create` and `QuoteEditorViewModel.saveDraft` both set `profileId = profileId` (the injected active id, never nil) on the `Client`/`Quote`, closing the `Quote.profileId?` (Swift `Optional`) vs D1 `NOT NULL` gap. Every list/picker query filters `profileId == pid && deletedAt == nil`.
- **Line items are a separate synced entity.** `saveDraft` diffs the working `[QuoteLineItem]` against the ids loaded at open: kept lines get a row-index `sortOrder` + an `upsert` enqueue; removed lines are soft-deleted + a `delete` enqueue. `QuoteLineItem.profileId` stays `nil` (child of a quote) — never set it (the `QuoteLineItem` `@Model` + its `QuoteLineItemSyncMapper` already exist and are unchanged).
- **The scaffold is frozen.** `Quote` + `QuoteLineItem` `@Model`s, their `init` labels, and `QuoteSyncMapper`/`QuoteLineItemSyncMapper` are NOT edited — they already exist and round-trip. Only `Client` is new on the model/sync side. `QuoteStatus`/`Quote.statusValue` and `QuoteTotals(lineItems:)` are pure additions.
- **Send applies the server response.** `QuoteEditorViewModel.send(api:)` calls `api.sendQuote(quoteId)` and applies `number`/`status`/`sentAt`/`subtotalCents`/`gstCents`/`totalCents` to the local `Quote` + saves + enqueues an upsert (sync reconciles). On failure it sets `errorMessage`, returns false, and the quote stays a `draft` with no number (numbers are minted server-side only on success). The `APIClient.sendQuote` 4-conformer pattern mirrors F3's `updateDevice` (Live `POST`, Stub, Preview, Mock with handler + recorded `sendQuoteCalls`).
- **GST math agrees with the backend.** `QuoteTotals.compute` uses `Int((Double(subtotal) * 0.10).rounded())` — the §4.2 formula the backend recomputes — so the on-device live total equals the server-recomputed total.
- **New overlays join BOTH lists.** `.quotes`/`.quoteEditor` are added to `sheetContent` (the EmptyView arm) AND to the `sheetBinding` exclusions — the non-associated `.quotes.id` in the `Set`, `.quoteEditor` via `hasPrefix("quoteEditor")` — exactly mirroring `.budgetEditor` (Task 10). The client picker is a `.sheet` local to the editor, NOT a router overlay, so it never touches `sheetBinding`.
- **The editor passes the shell's APIClient.** `QuoteEditorView` receives `api: captureAPI` from `ShellView`, so the hermetic UI test's `StubAPIClient.sendQuote` (deterministic, `emailed:false`) drives Send without a network call; the success overlay shows the "Quote ready!" + "View PDF" degraded copy.
- **Adding `.client` breaks 3 existing assertions — Task 1 fixes them.** `EntityType.allCases.count` becomes **15**. `SnapceiptTests/EntityTypeTests.swift` (`count` + `rawValues`) and `SnapceiptTests/SwiftDataModelTests.swift` (`entityTypeCount`) hard-code 14 / the exact 14-element raw array and MUST be updated in Task 1, or that task's GREEN step goes RED on those existing suites. Also bump the "14 syncable…" doc comments in `EntityType.swift` + `ModelContainer+Snapceipt.swift`. (Verified: exactly these two test files assert 14; `AppLaunchTests`/`SmokeTests` assert no seed/model counts, so the Task 15 seed + the `Client.self` registration are otherwise safe.)
- **Single-slot overlays: Done returns to HOME, not the list.** `.quotes` and `.quoteEditor` share one `router.overlay` slot (mutually exclusive), so opening the editor REPLACES the list. The editor's "Done"/close → `router.dismissOverlay()` → `overlay = nil` → the shell shows **Home** (`shell.home`), NOT the quotes list — identical to the documented `BudgetsUITests` behavior. `QuotesUITests` asserts the return-to-Home accordingly (Task 16). The sent quote is reachable again by re-opening Create Quote → list (acceptable v1 UX, matching budgets).

---

NOTE: NEVER `git add Snapceipt.xcodeproj` — it is xcodegen-generated + git-ignored. Every file-creating task above runs `/opt/homebrew/bin/xcodegen generate` before `xcodebuild`.
