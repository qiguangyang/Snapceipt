# F6 Email-in — iOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A minimal Email-in surface on the Profile tab — an inbox-address card (copy / share / rotate) and a failed-first inbox list of `email_in` transactions with a review-and-fix editor — backed by two new `APIClient` methods.

**Architecture:** Email-in items are ordinary `Transaction`s (`source == "email_in"`) that the existing sync pulls down, so the list is local-first SwiftData; only the address card needs the network. A new `EmailInViewModel` (`@Observable @MainActor`, deps injected — mirrors `QuoteListViewModel`/`BudgetListViewModel`) owns the failed-first query, the address fetch/rotate via `APIClient`, and the review-save (which flips `failed → done` and enqueues a sync upsert). Navigation reuses the full-screen-overlay pattern (`.emailIn` route → `RootView` overlay). No new `@Model` and no `EntityType` change.

**Tech Stack:** SwiftUI + SwiftData (iOS 17+), Swift Testing (`@Test`/`@Suite`) + XCUITest, XcodeGen (`project.yml`), the app's custom sync seam (`SyncEnqueuing`).

**Authoritative contract:** §3 of `docs/superpowers/specs/2026-06-01-email-in-design.md`. The backend stores `amount_cents` SIGNED (expense < 0, income > 0) and `gst_cents` as a positive magnitude — the review-save below applies the same sign rule.

**Baseline:** iOS unit 311 / UI 11 (per the F5 wrap). Build + test with XcodeGen first:

```bash
/opt/homebrew/bin/xcodegen generate
xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing 'SnapceiptTests/<SuiteTypeName>'
```

Run `xcodegen generate` before any `xcodebuild`. NEVER `git add` the generated `Snapceipt.xcodeproj` (it is git-ignored). `-only-testing` selectors use Swift TYPE names, not `@Suite` display strings. Trust `xcodebuild`, not SourceKit file-level diagnostics (no module context → phantom errors).

---

### Task 1: `InboxAddressResponse` DTO + two `APIClient` methods (all four conformers)

**Files:**
- Modify: `Snapceipt/Sync/DTOs.swift` (add `InboxAddressResponse`)
- Modify: `Snapceipt/Sync/APIClient.swift` (protocol + `LiveAPIClient`)
- Modify: `Snapceipt/Sync/StubAPIClient.swift`
- Modify: `Snapceipt/Features/Auth/SignInView.swift` (`PreviewAPIClient`)
- Modify: `SnapceiptTests/Mocks/MockAPIClient.swift`
- Test: `SnapceiptTests/InboxAddressResponseTests.swift`

- [ ] **Step 1: Write the failing test**

Create `SnapceiptTests/InboxAddressResponseTests.swift`:

```swift
import Testing
import Foundation
@testable import Snapceipt

@Suite("InboxAddressResponse")
struct InboxAddressResponseTests {
    @Test("decodes the backend payload")
    func decodes() throws {
        let json = #"{"profileId":"p1","token":"abc123","address":"r.abc123@in.snapceipt.app"}"#
        let res = try JSONDecoder().decode(InboxAddressResponse.self, from: Data(json.utf8))
        #expect(res.profileId == "p1")
        #expect(res.token == "abc123")
        #expect(res.address == "r.abc123@in.snapceipt.app")
    }

    @MainActor
    @Test("MockAPIClient records profileInbox + rotate calls")
    func mockRecords() async throws {
        let mock = MockAPIClient()
        mock.profileInboxHandler = { pid in
            InboxAddressResponse(profileId: pid, token: "t1", address: "r.t1@in.snapceipt.app")
        }
        mock.rotateProfileInboxHandler = { pid in
            InboxAddressResponse(profileId: pid, token: "t2", address: "r.t2@in.snapceipt.app")
        }
        let a = try await mock.profileInbox(profileId: "p9")
        let b = try await mock.rotateProfileInbox(profileId: "p9")
        #expect(a.token == "t1")
        #expect(b.token == "t2")
        #expect(mock.profileInboxCalls == ["p9"])
        #expect(mock.rotateProfileInboxCalls == ["p9"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild build-for-testing -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: BUILD FAILS — `InboxAddressResponse` unknown / `MockAPIClient` has no `profileInboxHandler`.

- [ ] **Step 3: Add the DTO**

In `Snapceipt/Sync/DTOs.swift`, add (mirroring `SendQuoteResponse`):

```swift
/// GET /profiles/:id/inbox + POST .../rotate — the per-profile inbox alias. The
/// client treats `address` as opaque (the server owns formatting).
struct InboxAddressResponse: Decodable, Equatable {
    let profileId: String
    let token: String
    let address: String
}
```

- [ ] **Step 4: Add the protocol methods + LiveAPIClient**

In `Snapceipt/Sync/APIClient.swift`, add to the `APIClient` protocol (after `sendQuote`):

```swift
    func profileInbox(profileId: String) async throws -> InboxAddressResponse
    func rotateProfileInbox(profileId: String) async throws -> InboxAddressResponse
```

In `LiveAPIClient` (after `sendQuote`):

```swift
    func profileInbox(profileId: String) async throws -> InboxAddressResponse {
        try await send("GET", "/profiles/\(profileId)/inbox", body: NoBody(), authenticated: true)
    }

    func rotateProfileInbox(profileId: String) async throws -> InboxAddressResponse {
        try await send("POST", "/profiles/\(profileId)/inbox/rotate", body: NoBody(), authenticated: true)
    }
```

(`NoBody()` is skipped by `makeRequest`, so the GET sends no body — same plumbing `sendQuote` uses.)

- [ ] **Step 5: Add to StubAPIClient**

In `Snapceipt/Sync/StubAPIClient.swift` (inside the `#if DEBUG` class):

```swift
    func profileInbox(profileId: String) async throws -> InboxAddressResponse {
        InboxAddressResponse(profileId: profileId, token: "stubtokeninitial",
                             address: "r.stubtokeninitial@in.snapceipt.app")
    }
    func rotateProfileInbox(profileId: String) async throws -> InboxAddressResponse {
        InboxAddressResponse(profileId: profileId, token: "stubtokenrotated",
                             address: "r.stubtokenrotated@in.snapceipt.app")
    }
```

- [ ] **Step 6: Add to PreviewAPIClient**

In `Snapceipt/Features/Auth/SignInView.swift` (`PreviewAPIClient`):

```swift
    func profileInbox(profileId: String) async throws -> InboxAddressResponse {
        InboxAddressResponse(profileId: profileId, token: "previewtoken",
                             address: "r.previewtoken@in.snapceipt.app")
    }
    func rotateProfileInbox(profileId: String) async throws -> InboxAddressResponse {
        InboxAddressResponse(profileId: profileId, token: "previewtoken2",
                             address: "r.previewtoken2@in.snapceipt.app")
    }
```

- [ ] **Step 7: Add to MockAPIClient**

In `SnapceiptTests/Mocks/MockAPIClient.swift`, add the handlers + call-recorders + methods:

```swift
    var profileInboxHandler: ((String) async throws -> InboxAddressResponse)?
    var rotateProfileInboxHandler: ((String) async throws -> InboxAddressResponse)?
    private(set) var profileInboxCalls: [String] = []
    private(set) var rotateProfileInboxCalls: [String] = []

    func profileInbox(profileId: String) async throws -> InboxAddressResponse {
        profileInboxCalls.append(profileId)
        guard let h = profileInboxHandler else { throw MockAPIClientError.unscripted }
        return try await h(profileId)
    }
    func rotateProfileInbox(profileId: String) async throws -> InboxAddressResponse {
        rotateProfileInboxCalls.append(profileId)
        guard let h = rotateProfileInboxHandler else { throw MockAPIClientError.unscripted }
        return try await h(profileId)
    }
```

- [ ] **Step 8: Run test to verify it passes**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing 'SnapceiptTests/InboxAddressResponseTests'`
Expected: PASS (2 tests). The full suite still builds (all four conformers satisfy the protocol).

- [ ] **Step 9: Commit**

```bash
git add Snapceipt/Sync/DTOs.swift Snapceipt/Sync/APIClient.swift Snapceipt/Sync/StubAPIClient.swift Snapceipt/Features/Auth/SignInView.swift SnapceiptTests/Mocks/MockAPIClient.swift SnapceiptTests/InboxAddressResponseTests.swift
git commit -m "$(cat <<'EOF'
feat(F6 iOS): InboxAddressResponse DTO + profileInbox/rotate on all 4 APIClients

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `EmailInViewModel`

**Files:**
- Create: `Snapceipt/Features/EmailIn/EmailInViewModel.swift`
- Test: `SnapceiptTests/EmailInViewModelTests.swift`

- [ ] **Step 1: Write the failing test**

Create `SnapceiptTests/EmailInViewModelTests.swift`:

```swift
import Testing
import Foundation
import SwiftData
@testable import Snapceipt

@MainActor
@Suite("EmailInViewModel")
struct EmailInViewModelTests {
    private func fixture() throws -> (ModelContext, MockSyncEngine, MockAPIClient) {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        return (ModelContext(container), MockSyncEngine(), MockAPIClient())
    }

    private func seedTxn(_ ctx: ModelContext, profileId: String, status: String, date: String, merchant: String) {
        ctx.insert(Transaction(userId: "u1", profileId: profileId, merchant: merchant, catKey: "office",
                               amountCents: -1000, txnDate: date, source: "email_in", extractionStatus: status))
    }

    @Test("inbox lists email_in txns for the active profile, failed first then newest")
    func failedFirst() throws {
        let (ctx, sync, api) = try fixture()
        seedTxn(ctx, profileId: "p1", status: "done", date: "2026-05-20", merchant: "Done-old")
        seedTxn(ctx, profileId: "p1", status: "failed", date: "2026-05-10", merchant: "Failed-old")
        seedTxn(ctx, profileId: "p1", status: "done", date: "2026-05-28", merchant: "Done-new")
        seedTxn(ctx, profileId: "p2", status: "failed", date: "2026-05-30", merchant: "Other-profile")
        try ctx.save()

        let vm = EmailInViewModel(context: ctx, sync: sync, api: api, userId: "u1", profileId: "p1")
        #expect(vm.inbox.map(\.merchant) == ["Failed-old", "Done-new", "Done-old"]) // p2 excluded
    }

    @Test("save applies edits, flips failed->done, signs the amount, and enqueues an upsert")
    func saveFlips() throws {
        let (ctx, sync, api) = try fixture()
        seedTxn(ctx, profileId: "p1", status: "failed", date: "2026-05-10", merchant: "")
        try ctx.save()
        let vm = EmailInViewModel(context: ctx, sync: sync, api: api, userId: "u1", profileId: "p1")
        let txn = vm.inbox[0]

        vm.save(txn, merchant: "Bunnings", amountCentsAbs: 4250, txnDate: "2026-05-11", catKey: "office")

        #expect(txn.merchant == "Bunnings")
        #expect(txn.amountCents == -4250)   // expense category -> negative
        #expect(txn.extractionStatus == "done")
        #expect(sync.calls.last?.op == "upsert")
        #expect(sync.calls.last?.entityType == .transaction)
    }

    @Test("save stores a positive amount for the income category")
    func saveIncomeSign() throws {
        let (ctx, sync, api) = try fixture()
        seedTxn(ctx, profileId: "p1", status: "done", date: "2026-05-10", merchant: "x")
        try ctx.save()
        let vm = EmailInViewModel(context: ctx, sync: sync, api: api, userId: "u1", profileId: "p1")
        vm.save(vm.inbox[0], merchant: "Client", amountCentsAbs: 9000, txnDate: "2026-05-10", catKey: "income")
        #expect(vm.inbox[0].amountCents == 9000)
    }

    @Test("loadAddress + rotate go through the API client")
    func addressFlow() async throws {
        let (ctx, sync, api) = try fixture()
        api.profileInboxHandler = { pid in InboxAddressResponse(profileId: pid, token: "t1", address: "r.t1@in.snapceipt.app") }
        api.rotateProfileInboxHandler = { pid in InboxAddressResponse(profileId: pid, token: "t2", address: "r.t2@in.snapceipt.app") }
        let vm = EmailInViewModel(context: ctx, sync: sync, api: api, userId: "u1", profileId: "p1")

        await vm.loadAddress()
        #expect(vm.address?.address == "r.t1@in.snapceipt.app")
        await vm.rotate()
        #expect(vm.address?.address == "r.t2@in.snapceipt.app")
        #expect(api.profileInboxCalls == ["p1"])
        #expect(api.rotateProfileInboxCalls == ["p1"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild build-for-testing -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: BUILD FAILS — `EmailInViewModel` unknown.

- [ ] **Step 3: Implement `Snapceipt/Features/EmailIn/EmailInViewModel.swift`**

```swift
import Foundation
import SwiftData

/// Drives the Email-in surface. The inbox list is local-first (email_in
/// transactions that sync down); only the address card needs the network.
/// `@MainActor`; deps injected for tests. Mirrors QuoteListViewModel.
@Observable
@MainActor
final class EmailInViewModel {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let sync: any SyncEnqueuing
    @ObservationIgnored private let api: any APIClient
    @ObservationIgnored private let userId: String
    @ObservationIgnored let profileId: String

    /// email_in transactions for the active profile — failed first, then newest date.
    private(set) var inbox: [Transaction] = []
    private(set) var address: InboxAddressResponse?
    private(set) var isLoadingAddress = false
    var errorMessage: String?

    init(context: ModelContext, sync: any SyncEnqueuing, api: any APIClient, userId: String, profileId: String) {
        self.context = context
        self.sync = sync
        self.api = api
        self.userId = userId
        self.profileId = profileId
        reload()
    }

    func reload() {
        let pid = profileId
        let d = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.profileId == pid && $0.source == "email_in" && $0.deletedAt == nil })
        let rows = (try? context.fetch(d)) ?? []
        inbox = rows.sorted { a, b in
            let aFailed = a.extractionStatus == "failed"
            let bFailed = b.extractionStatus == "failed"
            if aFailed != bFailed { return aFailed }    // failed rows first
            return a.txnDate > b.txnDate                // then newest by date
        }
    }

    func loadAddress() async {
        isLoadingAddress = true
        errorMessage = nil
        defer { isLoadingAddress = false }
        do {
            address = try await api.profileInbox(profileId: profileId)
        } catch {
            errorMessage = "Couldn't load your inbox address."
        }
    }

    func rotate() async {
        do {
            address = try await api.rotateProfileInbox(profileId: profileId)
        } catch {
            errorMessage = "Couldn't rotate the address."
        }
    }

    /// Apply review edits, flip failed->done, sign the amount per category, and
    /// enqueue an upsert. `amountCentsAbs` is the positive magnitude from the editor.
    func save(_ txn: Transaction, merchant: String, amountCentsAbs: Int, txnDate: String, catKey: String) {
        let sign = catKey == "income" ? 1 : -1
        txn.merchant = merchant
        txn.amountCents = sign * abs(amountCentsAbs)
        txn.txnDate = txnDate
        txn.catKey = catKey
        if txn.extractionStatus == "failed" { txn.extractionStatus = "done" }
        txn.updatedAt = Epoch.nowMs()
        try? context.save()
        reload()
        sync.enqueue(op: "upsert", entityType: .transaction, entity: txn)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing 'SnapceiptTests/EmailInViewModelTests'`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Snapceipt/Features/EmailIn/EmailInViewModel.swift SnapceiptTests/EmailInViewModelTests.swift
git commit -m "$(cat <<'EOF'
feat(F6 iOS): EmailInViewModel — failed-first inbox, address fetch/rotate, review-save

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Navigation — `.emailIn` route, Profile-tab row, AccessibilityIDs, RootView wiring

**Files:**
- Modify: `Snapceipt/App/Router.swift` (add `.emailIn` to `Overlay` + its `id`)
- Modify: `Snapceipt/Shared/AccessibilityID.swift` (the email-in identifiers)
- Modify: `Snapceipt/Features/Profiles/ProfileTabView.swift` (the row + `onOpenEmailIn`)
- Modify: `Snapceipt/App/RootView.swift` (overlay wiring + sheet exclusions + thread `onOpenEmailIn`)

This task wires navigation but the overlay body is a placeholder `EmptyView`-free stub until Task 4 (so it compiles). To keep the build green, Task 3 references `EmailInView`, so create a minimal stub in this task and flesh it out in Task 4. Simplest: build the real `EmailInView` in Task 4 first is circular — instead, this task adds a tiny placeholder `EmailInView` file that Task 4 replaces. To avoid churn, **do Task 3 and Task 4 together is tempting, but keep them split**: Task 3 wires to `EmailInView(...)` and includes a minimal compiling `EmailInView`/`EmailInReviewView` placeholder; Task 4 replaces those file bodies with the full UI.

- [ ] **Step 1: Add the `.emailIn` overlay case**

In `Snapceipt/App/Router.swift`, add to the `Overlay` enum (after `.quoteEditor`):

```swift
    case emailIn
```

And to the `id` switch:

```swift
        case .emailIn: return "emailIn"
```

- [ ] **Step 2: Add the AccessibilityIDs**

In `Snapceipt/Shared/AccessibilityID.swift`, add an Email-in group:

```swift
    // Email-in
    static let profileRowEmailIn = "profile.row.emailin"
    static let emailInScreen = "emailin.screen"
    static let emailInAddress = "emailin.address"
    static let emailInCopy = "emailin.copy"
    static let emailInRotate = "emailin.rotate"
    static let emailInListRowPrefix = "emailin.row."     // + transaction.id
    static let emailInReviewScreen = "emailin.review.screen"
    static let emailInReviewSave = "emailin.review.save"
```

- [ ] **Step 3: Add the Profile-tab row**

In `Snapceipt/Features/Profiles/ProfileTabView.swift`, add the closure property and the row. Update the struct's stored properties:

```swift
struct ProfileTabView: View {
    let onOpenNotifications: () -> Void
    let onOpenBudgets: () -> Void
    let onOpenEmailIn: () -> Void
```

Add the row after the Budgets row in `body`:

```swift
                row(icon: "envelope", title: "Email-in receipts",
                    id: AccessibilityID.profileRowEmailIn, action: onOpenEmailIn)
```

- [ ] **Step 4: Create compiling placeholders for the views**

Create `Snapceipt/Features/EmailIn/EmailInView.swift`:

```swift
import SwiftUI
import SwiftData

struct EmailInView: View {
    @State private var vm: EmailInViewModel
    let onClose: () -> Void
    let onReview: (String) -> Void

    init(context: ModelContext, sync: any SyncEnqueuing, api: any APIClient,
         userId: String, profileId: String,
         onClose: @escaping () -> Void, onReview: @escaping (String) -> Void) {
        _vm = State(initialValue: EmailInViewModel(context: context, sync: sync, api: api,
                                                   userId: userId, profileId: profileId))
        self.onClose = onClose
        self.onReview = onReview
    }

    var body: some View {
        VStack { Text("Email-in") }
            .accessibilityIdentifier(AccessibilityID.emailInScreen)
            .task { await vm.loadAddress() }
    }
}
```

Create `Snapceipt/Features/EmailIn/EmailInReviewView.swift`:

```swift
import SwiftUI
import SwiftData

struct EmailInReviewView: View {
    let vm: EmailInViewModel
    let transactionId: String
    let onClose: () -> Void

    var body: some View {
        VStack { Text("Review") }
            .accessibilityIdentifier(AccessibilityID.emailInReviewScreen)
    }
}
```

(These are replaced wholesale in Task 4. They exist now only so Task 3's RootView wiring compiles.)

- [ ] **Step 5: Wire RootView**

In `Snapceipt/App/RootView.swift`:

(a) Thread `onOpenEmailIn` where `ProfileTabView` is constructed (find `ProfileTabView(onOpenNotifications:..., onOpenBudgets:...)` and add):

```swift
                    onOpenEmailIn: { router.present(.emailIn) }
```

(b) Add the full-screen overlays (after the `.quotes` overlay block):

```swift
            .overlay {
                if router.overlay == .emailIn {
                    EmailInView(context: profiles.context, sync: sync, userId: profiles.userId,
                                api: api, profileId: profiles.activeProfileId,
                                onClose: { router.dismissOverlay() },
                                onReview: { router.present(.emailInReview(id: $0)) })
                        .environment(\.accent, accent).transition(.opacity)
                }
            }
```

This references a `.emailInReview(id:)` route — add it too. Go back to `Router.swift` and add:

```swift
    case emailInReview(id: String)
```

and its id:

```swift
        case .emailInReview(let id): return "emailInReview-\(id)"
```

Then add the review overlay in `RootView.swift`:

```swift
            .overlay {
                if case let .emailInReview(id) = router.overlay {
                    EmailInReviewView(
                        vm: EmailInViewModel(context: profiles.context, sync: sync, api: api,
                                             userId: profiles.userId, profileId: profiles.activeProfileId),
                        transactionId: id,
                        onClose: { router.dismissOverlay() })
                        .environment(\.accent, accent).transition(.opacity)
                }
            }
```

Note: confirm how `api` (the `APIClient`) is available in `ShellView` — find how `QuoteListView`/`ExportSheet` obtain the API client (it is injected into `ShellView`; reuse that exact property name, e.g. `api` or `apiClient`). If the property is named differently, use that name in both overlay blocks.

(c) Add `.emailIn` and `.emailInReview` to the sheet-binding exclusion `switch` and the `fullScreen` set in `sheetBinding`, and to the `EmptyView()` arm of `sheetContent` — mirroring how `.quotes`/`.quoteEditor` are listed:

In the `sheetBinding` getter `switch`, add `.emailIn, .emailInReview` to the `case` that returns `nil`.

In the `fullScreen` set, add `Overlay.emailIn.id`.

In the setter guard, add `!cur.id.hasPrefix("emailInReview")` alongside the existing `quoteEditor`/`loyaltyCard` prefix guards.

In `sheetContent(for:)`, add `.emailIn, .emailInReview` to the `case ...: EmptyView()` arm (the full-screen-handled list).

- [ ] **Step 6: Build + run existing UI/unit suites to confirm no regression**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing 'SnapceiptTests/EmailInViewModelTests'`
Expected: PASS (build succeeds with the new navigation; the VM tests still pass).

- [ ] **Step 7: Commit**

```bash
git add Snapceipt/App/Router.swift Snapceipt/Shared/AccessibilityID.swift Snapceipt/Features/Profiles/ProfileTabView.swift Snapceipt/App/RootView.swift Snapceipt/Features/EmailIn/EmailInView.swift Snapceipt/Features/EmailIn/EmailInReviewView.swift
git commit -m "$(cat <<'EOF'
feat(F6 iOS): .emailIn / .emailInReview routes + Profile row + RootView wiring

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `EmailInView` (address card + inbox list) and `EmailInReviewView`

**Files:**
- Modify: `Snapceipt/Features/EmailIn/EmailInView.swift` (replace placeholder)
- Modify: `Snapceipt/Features/EmailIn/EmailInReviewView.swift` (replace placeholder)

This task has no new unit tests (the VM is already covered); it is verified by the build and by the UI test in Task 6. Reuse the full-screen overlay chrome (`LbHeader`) and design primitives (`Card`, `IconCircle`, `EmptyArt`) used by `QuoteListView`/`BudgetListView`.

- [ ] **Step 1: Replace `EmailInView.swift`**

```swift
import SwiftUI
import SwiftData

/// The Email-in surface: an inbox-address card (copy / share / rotate) above a
/// failed-first list of email_in transactions. Tapping a row opens the review editor.
struct EmailInView: View {
    @State private var vm: EmailInViewModel
    @State private var shareItem: String?
    let onClose: () -> Void
    let onReview: (String) -> Void
    @Environment(\.accent) private var accent

    init(context: ModelContext, sync: any SyncEnqueuing, api: any APIClient,
         userId: String, profileId: String,
         onClose: @escaping () -> Void, onReview: @escaping (String) -> Void) {
        _vm = State(initialValue: EmailInViewModel(context: context, sync: sync, api: api,
                                                   userId: userId, profileId: profileId))
        self.onClose = onClose
        self.onReview = onReview
    }

    var body: some View {
        VStack(spacing: 0) {
            LbHeader(title: "Email-in receipts", onClose: onClose, onAdd: {})
            ScrollView {
                VStack(spacing: 14) {
                    addressCard
                    if vm.inbox.isEmpty {
                        emptyState
                    } else {
                        ForEach(vm.inbox, id: \.id) { txn in
                            row(txn)
                        }
                    }
                }
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream)
        .accessibilityIdentifier(AccessibilityID.emailInScreen)
        .task { await vm.loadAddress() }
        .sheet(isPresented: Binding(get: { shareItem != nil }, set: { if !$0 { shareItem = nil } })) {
            if let item = shareItem { ActivityView(items: [item]) }
        }
    }

    private var addressCard: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Forward receipts to").font(.ui(13, .semibold)).foregroundStyle(Palette.ink3)
                Text(vm.address?.address ?? "Loading…")
                    .font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
                    .textSelection(.enabled).lineLimit(2)
                    .accessibilityIdentifier(AccessibilityID.emailInAddress)
                HStack(spacing: 10) {
                    actionChip("Copy", "doc.on.doc", id: AccessibilityID.emailInCopy) {
                        if let a = vm.address?.address { UIPasteboard.general.string = a }
                    }
                    actionChip("Share", "square.and.arrow.up", id: nil) {
                        shareItem = vm.address?.address
                    }
                    actionChip("Rotate", "arrow.triangle.2.circlepath", id: AccessibilityID.emailInRotate) {
                        Task { await vm.rotate() }
                    }
                }
            }
        }
    }

    private func actionChip(_ title: String, _ systemImage: String, id: String?, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.ui(13, .semibold)).foregroundStyle(accent.base)
                .padding(.vertical, 8).padding(.horizontal, 12)
                .background(accent.soft, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id ?? "emailin.share")
    }

    private func row(_ txn: Transaction) -> some View {
        Button { onReview(txn.id) } label: {
            Card(padding: 14) {
                HStack(spacing: 12) {
                    IconCircle(name: txn.extractionStatus == "failed" ? "exclamationmark" : "receipt",
                               tint: accent.base, soft: accent.soft, size: 38, iconSize: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(txn.merchant.isEmpty ? "Untitled receipt" : txn.merchant)
                            .font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                        Text(txn.txnDate).font(.ui(12.5)).foregroundStyle(Palette.ink3)
                    }
                    Spacer()
                    if txn.extractionStatus == "failed" {
                        Text("Needs review").font(.ui(11.5, .semibold)).foregroundStyle(.white)
                            .padding(.vertical, 4).padding(.horizontal, 8)
                            .background(Color.orange, in: Capsule())
                    } else {
                        Text(Money.format(cents: txn.amountCents, code: txn.currency))
                            .font(.ui(14, .semibold)).foregroundStyle(Palette.ink)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.emailInListRowPrefix + txn.id)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            EmptyArt(kind: .receipt, size: 120)
            Text("No emailed receipts yet").font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
            Text("Forward a receipt to the address above and it'll show up here for review.")
                .font(.ui(13)).foregroundStyle(Palette.ink3).multilineTextAlignment(.center)
        }
        .padding(.top, 40)
    }
}
```

Note: confirm the helper names against the codebase before relying on them — `Money.format(cents:code:)`, `ActivityView(items:)`, `Card`, `IconCircle`, `Palette`, `.font(.ui(...))`, `EmptyArt`. The Explore brief confirmed `LbHeader`, `EmptyArt`, `Card`, `IconCircle`. For currency formatting and the share sheet, use whatever `QuoteListView`/`ExportSheet` already use (grep `ActivityView` and the money formatter and copy the exact call). If `IconCircle` does not accept SF Symbol names like `"receipt"`, use the project's `Icon`/symbol convention from `ProfileTabView` (`IconCircle(name: "wallet", ...)`).

- [ ] **Step 2: Replace `EmailInReviewView.swift`**

```swift
import SwiftUI
import SwiftData

/// Review + fix a single email_in transaction, then Save (flips failed->done).
struct EmailInReviewView: View {
    let vm: EmailInViewModel
    let transactionId: String
    let onClose: () -> Void
    @Environment(\.accent) private var accent

    @State private var merchant = ""
    @State private var amountText = ""
    @State private var txnDate = ""
    @State private var catKey = "office"
    @State private var loaded = false

    private let catKeys = ["meals", "groceries", "fuel", "software", "office", "home", "health", "travel", "income", "custom"]

    private var txn: Transaction? { vm.inbox.first { $0.id == transactionId } }

    var body: some View {
        VStack(spacing: 0) {
            LbHeader(title: "Review receipt", onClose: onClose, onAdd: {})
            Form {
                Section("Details") {
                    TextField("Merchant", text: $merchant)
                    TextField("Amount (AUD)", text: $amountText).keyboardType(.decimalPad)
                    TextField("Date (YYYY-MM-DD)", text: $txnDate)
                    Picker("Category", selection: $catKey) {
                        ForEach(catKeys, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                }
                Section {
                    Button("Save") { save() }
                        .accessibilityIdentifier(AccessibilityID.emailInReviewSave)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream)
        .accessibilityIdentifier(AccessibilityID.emailInReviewScreen)
        .onAppear {
            guard !loaded, let t = txn else { return }
            merchant = t.merchant
            amountText = String(format: "%.2f", Double(abs(t.amountCents)) / 100.0)
            txnDate = t.txnDate
            catKey = t.catKey
            loaded = true
        }
    }

    private func save() {
        guard let t = txn else { return }
        let dollars = Double(amountText) ?? 0
        let cents = Int((dollars * 100).rounded())
        vm.save(t, merchant: merchant, amountCentsAbs: cents, txnDate: txnDate, catKey: catKey)
        onClose()
    }
}
```

- [ ] **Step 3: Build + run the VM suite (confirms the views compile)**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing 'SnapceiptTests/EmailInViewModelTests'`
Expected: PASS (build succeeds; 4 VM tests pass).

- [ ] **Step 4: Commit**

```bash
git add Snapceipt/Features/EmailIn/EmailInView.swift Snapceipt/Features/EmailIn/EmailInReviewView.swift
git commit -m "$(cat <<'EOF'
feat(F6 iOS): EmailInView (address card + failed-first list) + review editor

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Seed two `email_in` transactions for the UI test

**Files:**
- Modify: `Snapceipt/App/AppLaunch.swift` (add to `applySeedIfNeeded`)

- [ ] **Step 1: Add the seed rows**

In `Snapceipt/App/AppLaunch.swift`, inside `applySeedIfNeeded`, after the existing business-profile (`p1`) transaction seeds and before `try? context.save()`, add:

```swift
        // F6: two email-in receipts on the business profile — one failed (needs review),
        // one done — so EmailInUITests can exercise the failed-first list + review flow.
        context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, merchant: "",
                                   catKey: "office", amountCents: 0, txnDate: dayISO(4),
                                   isAi: true, source: "email_in", extractionStatus: "failed"))
        context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, merchant: "Officeworks",
                                   catKey: "office", amountCents: -45_00, txnDate: dayISO(2),
                                   isAi: true, gstCents: 4_09, source: "email_in", extractionStatus: "done"))
```

(`dayISO` and `p1` are already defined in `applySeedIfNeeded` per the seed structure.)

- [ ] **Step 2: Build to confirm it compiles**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild build-for-testing -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: BUILD SUCCEEDS.

- [ ] **Step 3: Commit**

```bash
git add Snapceipt/App/AppLaunch.swift
git commit -m "$(cat <<'EOF'
test(F6 iOS): seed failed + done email_in transactions for the UI test

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: `EmailInUITests` (hermetic, seeded)

**Files:**
- Create: `SnapceiptUITests/EmailInUITests.swift`

- [ ] **Step 1: Write the UI test**

Create `SnapceiptUITests/EmailInUITests.swift`:

```swift
import XCTest

final class EmailInUITests: UITestCase {
    func testEmailInAddressCardAndReviewFlow() {
        launchSeeded()

        // Navigate to the Profile tab.
        let profileTab = app.buttons[AccessibilityID.shellProfile]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 10), "Profile tab missing")
        profileTab.tap()

        // Open Email-in.
        let row = app.buttons[AccessibilityID.profileRowEmailIn]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Email-in row missing")
        row.tap()

        // Address card renders (stub alias).
        let address = app.staticTexts[AccessibilityID.emailInAddress]
        XCTAssertTrue(address.waitForExistence(timeout: 5), "Inbox address not shown")
        XCTAssertTrue(address.label.contains("@in.snapceipt.app"), "Address not formatted")

        // The failed row should be present and tappable (failed-first ordering).
        let screen = app.otherElements[AccessibilityID.emailInScreen]
        XCTAssertTrue(screen.waitForExistence(timeout: 5))
        let failedRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.emailInListRowPrefix)).firstMatch
        XCTAssertTrue(failedRow.waitForExistence(timeout: 5), "No email-in rows")
        failedRow.tap()

        // Review editor opens; save.
        let review = app.otherElements[AccessibilityID.emailInReviewScreen]
        XCTAssertTrue(review.waitForExistence(timeout: 5), "Review screen did not open")
        let save = app.buttons[AccessibilityID.emailInReviewSave]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "Save button missing")
        save.tap()

        // Back on the Email-in list.
        XCTAssertTrue(app.otherElements[AccessibilityID.emailInScreen].waitForExistence(timeout: 5),
                      "Did not return to the Email-in list after save")

        // Rotate the address (the stub returns a different alias).
        let rotate = app.buttons[AccessibilityID.emailInRotate]
        XCTAssertTrue(rotate.waitForExistence(timeout: 5), "Rotate button missing")
        rotate.tap()
    }
}
```

Note: confirm the Profile-tab accessibility id. The brief showed `AccessibilityID.shellHome`/`shellTabBar` but not the profile tab id — grep `AccessibilityID` for the profile-tab button identifier (e.g. `shellProfile`) and use the exact constant. If the tab is reached differently in the seeded shell, mirror how `ShellUITests` navigates tabs.

- [ ] **Step 2: Run the UI test**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing 'SnapceiptUITests/EmailInUITests'`
Expected: PASS (1 UI test).

- [ ] **Step 3: Commit**

```bash
git add SnapceiptUITests/EmailInUITests.swift
git commit -m "$(cat <<'EOF'
test(F6 iOS): hermetic EmailInUITests — address card + review + rotate

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Full-suite green gate

**Files:** none (verification only)

- [ ] **Step 1: Run the entire iOS suite**

Run:
```bash
/opt/homebrew/bin/xcodegen generate
xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```
Expected: all tests pass. Unit count = 311 baseline + 6 new (`InboxAddressResponseTests` ×2, `EmailInViewModelTests` ×4) = 317; UI count = 11 baseline + 1 (`EmailInUITests`) = 12. 0 failures.

- [ ] **Step 2: Confirm the `.xcodeproj` is not staged**

Run: `git status --short`
Expected: `Snapceipt.xcodeproj` does NOT appear (it is git-ignored / never staged).

- [ ] **Step 3: Final commit if anything pending**

If `git status` shows only already-committed work, this task is a no-op. Otherwise commit any straggling test-support edits:

```bash
git commit -am "$(cat <<'EOF'
test(F6 iOS): full suite green — 317 unit / 12 UI

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage (§5 iOS components + §3.4/§3.5 contract):**
- `Features/EmailIn/EmailInViewModel.swift` (failed-first profile-scoped query; review-save flips failed→done + signs amount + enqueues; address fetch/rotate) → Task 2. ✓
- `Features/EmailIn/EmailInView.swift` (address card with copy/share/rotate + failed-first list + empty state) → Task 4. ✓
- `Features/EmailIn/EmailInReviewView.swift` (Transaction-bound editor + Save) → Task 4. ✓
- `APIClient` + 3 conformers + `MockAPIClient` (`profileInbox`/`rotateProfileInbox`) → Task 1. ✓
- `DTOs.swift` `InboxAddressResponse` → Task 1. ✓
- `Router` `.emailIn` (+ `.emailInReview` for the editor overlay) → Task 3. ✓
- `RootView` overlay wiring + sheet exclusions → Task 3. ✓
- `ProfileTabView` "Email-in receipts" row → Task 3. ✓
- `AccessibilityID` additions → Task 3. ✓
- `AppLaunch` seed (1 failed + 1 done `email_in`) → Task 5. ✓
- §3.5 profile scoping (filter by `profileId` AND `source == "email_in"`) → Task 2 (asserted: p2 row excluded). ✓
- §3.4 contract (signed amount: backend stores expense-negative; review-save re-applies sign) → Task 2 (`saveFlips` expects `-4250`, `saveIncomeSign` expects `+9000`). ✓
- §7.2 iOS tests (VM failed-first + review-save + enqueue + address flow; `InboxAddressResponse` decode + Mock-records; hermetic UI test) → Tasks 1, 2, 6. ✓

**Placeholder scan:** No TBD/TODO. Every code step shows full code. The conditional verifications are explicit and name their fallback: the `api`/`apiClient` property name in `ShellView` (Task 3 & 4), the `Money.format`/`ActivityView`/`IconCircle` helper names (Task 4), and the profile-tab accessibility id (Task 6) — each says "grep the existing usage and copy the exact symbol." Task 3 deliberately ships compiling placeholder views that Task 4 replaces, so each task builds green. ✓

**Type consistency:** `EmailInViewModel(context:sync:api:userId:profileId:)` is constructed identically in Tasks 2, 3, 4; `save(_:merchant:amountCentsAbs:txnDate:catKey:)` signature matches between the VM (Task 2), its tests (Task 2), and `EmailInReviewView.save()` (Task 4); `InboxAddressResponse(profileId:token:address:)` memberwise init used in Stub/Preview/Mock (Task 1); the `.emailIn` / `.emailInReview(id:)` overlay cases defined in Task 3 are consumed by the same-task `RootView` blocks; accessibility-id constants referenced in Tasks 4 & 6 are all declared in Task 3. ✓
