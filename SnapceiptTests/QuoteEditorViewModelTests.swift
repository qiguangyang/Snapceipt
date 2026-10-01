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

    @Test("a new quote uses the active profile's GST rate (15%) for totals + label")
    func newQuoteUsesProfileRate() throws {
        let (ctx, sync) = try makeFixture()
        ctx.insert(Profile(id: "p1", userId: "u1", name: "Biz", type: "business",
                           accent1: "FF6B35", accent2: "0E7C72", accent3: "5B6CFF", gstRateBp: 1500))
        try ctx.save()
        let v = vm(ctx, sync)
        v.load(id: nil)
        v.addLine(); v.lineItems[0].unitPriceCents = 200_00   // $200 ex-GST
        #expect(v.gstRatePercentText == "15")
        #expect(v.totals.gst == 30_00)      // 15% of $200, NOT 10% ($20)
        #expect(v.totals.total == 230_00)
    }

    @Test("addLine() appends a blank line and returns its id (so the editor can focus its Description)")
    func addLineReturnsNewId() throws {
        let (ctx, sync) = try makeFixture()
        let v = vm(ctx, sync)
        v.load(id: nil)
        let id = v.addLine()
        #expect(id != nil)
        #expect(v.lineItems.count == 1)
        #expect(v.lineItems.last?.id == id)
        #expect(v.lineItems.last?.itemDescription == "")
    }

    @Test("canSaveDraft gates an empty quote: false when blank, true with a client or a line")
    func canSaveDraftGate() throws {
        let (ctx, sync) = try makeFixture()
        let v = vm(ctx, sync)
        v.load(id: nil)
        #expect(v.canSaveDraft == false)            // brand-new: no client, no lines
        v.setClient(name: "Acme Pty", email: nil)
        #expect(v.canSaveDraft == true)             // a client is enough
    }

    @Test("Save Draft persists a draft-status quote (listed) and is idempotent on a second save")
    func saveDraftPersistsDraftAndIsIdempotent() throws {
        let (ctx, sync) = try makeFixture()
        let v = vm(ctx, sync)
        v.load(id: nil)
        v.setClient(name: "Acme Pty", email: nil)
        v.addLine(); v.lineItems[0].unitPriceCents = 100_00
        v.saveDraft()
        v.saveDraft()   // a second save (e.g. re-tap) must not duplicate
        let quotes = try ctx.fetch(FetchDescriptor<Quote>())
        #expect(quotes.count == 1)
        #expect(quotes.first?.status == QuoteStatus.draft.rawValue)   // stays a draft → listed + re-editable
        let liveLines = try ctx.fetch(FetchDescriptor<QuoteLineItem>()).filter { $0.deletedAt == nil }
        #expect(liveLines.count == 1)
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
        #expect(v.quoteId != nil)
        // New quotes are valid for 28 days (a real date, shown as "Valid until <date>").
        #expect(v.validUntil == QuoteEditorViewModel.validUntilPlus28())
        #expect(QuoteEditorViewModel.validUntilPlus28() != QuoteEditorViewModel.dueDatePlus14())
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

    @Test("GST inclusive: total stays the entered sum; gst is the embedded portion")
    func gstInclusiveTotals() throws {
        let (ctx, sync) = try makeFixture()
        let v = vm(ctx, sync)
        v.load(id: nil)
        v.addLine(); v.lineItems[0].unitPriceCents = 165_00
        v.addLine(); v.lineItems[1].unitPriceCents = 45_00
        v.gstInclusive = true
        #expect(v.totals.total == 210_00)     // unchanged from entered 165+45
        #expect(v.totals.gst == 19_09)        // round(210/11)
        #expect(v.totals.subtotal == 190_91)  // ex-GST base
    }

    @Test("saveDraft persists gstInclusive and reload restores it")
    func gstInclusiveRoundTrips() throws {
        let (ctx, sync) = try makeFixture()
        let v = vm(ctx, sync)
        v.load(id: nil)
        v.setClient(name: "Acme", email: nil)
        v.addLine(); v.lineItems[0].unitPriceCents = 110_00
        v.gstInclusive = true
        v.saveDraft()
        let id = v.quoteId!
        let stored = try ctx.fetch(FetchDescriptor<Quote>(predicate: #Predicate { $0.id == id }))[0]
        #expect(stored.gstInclusive == true)
        #expect(stored.totalCents == 110_00)  // inclusive: total == entered sum
        #expect(stored.gstCents == 10_00)
        #expect(stored.subtotalCents == 100_00)

        let v2 = vm(ctx, sync)
        v2.load(id: id)
        #expect(v2.gstInclusive == true)
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
        let v2 = vm(ctx, sync)
        v2.load(id: id)
        #expect(v2.lineItems.count == 2)
        v2.removeLine(v2.lineItems[0])
        v2.saveDraft()
        let live = try ctx.fetch(FetchDescriptor<QuoteLineItem>(predicate: #Predicate { $0.deletedAt == nil }))
        #expect(live.count == 1)
        #expect(sync.calls.contains { $0.entityType == .quoteLineItem && $0.op == "delete" })
    }

    @Test("setClient snapshots clientAddress; saveDraft persists it and reload restores it")
    func clientAddressSnapshots() throws {
        let (ctx, sync) = try makeFixture()
        let v = vm(ctx, sync)
        v.load(id: nil)
        v.setClient(name: "Acme", email: "a@acme.com", address: "9 Client Rd\nMelbourne VIC 3000")
        v.addLine(); v.lineItems[0].unitPriceCents = 50_00
        #expect(v.clientAddress == "9 Client Rd\nMelbourne VIC 3000")
        v.saveDraft()
        let id = v.quoteId!
        let stored = try ctx.fetch(FetchDescriptor<Quote>(predicate: #Predicate { $0.id == id }))[0]
        #expect(stored.clientAddress == "9 Client Rd\nMelbourne VIC 3000")

        let v2 = vm(ctx, sync)
        v2.load(id: id)
        #expect(v2.clientAddress == "9 Client Rd\nMelbourne VIC 3000")
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

    @Test("send saves the draft, calls sendQuote once, and applies url/number/emailed + sets status sent")
    func sendApplies() async throws {
        let (ctx, sync) = try makeFixture()
        let mock = MockAPIClient()
        mock.sendQuoteHandler = { _ in
            SendQuoteResponse(url: "https://api.snapceipt.cc/q/tok", emailed: true, number: "SN-0042")
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
        #expect(v.pdfUrl == "https://api.snapceipt.cc/q/tok")
        #expect(v.statusValue == .sent)        // status is set locally on success
        #expect(v.emailed == true)
        let q = try ctx.fetch(FetchDescriptor<Quote>(predicate: #Predicate { $0.deletedAt == nil }))[0]
        #expect(q.number == "SN-0042")
        #expect(q.status == "sent")
    }

    @Test("send flushes the outbox BEFORE calling sendQuote (the quote must exist server-side)")
    func sendFlushesBeforeSending() async throws {
        let (ctx, sync) = try makeFixture()
        let mock = MockAPIClient()
        // Capture how many flushes had completed at the moment sendQuote is invoked —
        // proves the outbox was drained (flushCount == 1) before the send call fires.
        var flushCountAtSend = -1
        mock.sendQuoteHandler = { _ in
            flushCountAtSend = sync.flushCount
            return SendQuoteResponse(url: "https://api.snapceipt.cc/q/tok", emailed: false, number: "SN-0001")
        }
        let v = vm(ctx, sync)
        v.load(id: nil)
        v.setClient(name: "Acme", email: "a@acme.com")
        v.addLine(); v.lineItems[0].unitPriceCents = 10_00
        let ok = await v.send(api: mock)
        #expect(ok == true)
        #expect(flushCountAtSend == 1)   // flush ran, and completed, before sendQuote
        #expect(sync.flushCount == 1)
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

    @Test func selectionPersistsClientId() throws {
        let (ctx, sync) = try makeFixture()
        let picker = ClientPickerViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1")
        let client = try #require(picker.create(name: "Acme", email: "old@example.com", mobilePhone: "0400000000", address: "Original address"))
        let editor = QuoteEditorViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1")
        editor.load(id: nil)
        editor.setClient(ClientSelection(client))
        editor.saveDraft()
        let loaded = QuoteEditorViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1")
        loaded.load(id: editor.quoteId)
        #expect(loaded.clientId == client.id)
        #expect(loaded.clientMobile == "0400000000" && loaded.clientAddress == "Original address")
        #expect(loaded.clientName == "Acme" && loaded.clientEmail == "old@example.com")
        #expect(sync.calls.first?.entityType == .client)
        loaded.setClient(name: "Legacy", email: nil)
        loaded.saveDraft()
        #expect(loaded.clientId == nil)
    }

    @Test func scopedClientLinksAndDeletedHistory() throws {
        let (ctx, sync) = try makeFixture()
        let live = Client(userId: "u1", profileId: "p1", name: "Live")
        let foreign = Client(userId: "u2", profileId: "p1", name: "Foreign")
        let other = Client(userId: "u1", profileId: "p2", name: "Other")
        let deleted = Client(userId: "u1", profileId: "p1", name: "Deleted", deletedAt: 1)
        for client in [live, foreign, other, deleted] { ctx.insert(client) }
        try ctx.save()
        let v = vm(ctx, sync); v.load(id: nil)
        for client in [foreign, other, deleted] {
            v.setClient(ClientSelection(client))
            #expect(v.saveDraft() == false)
            #expect(v.errorMessage != nil && sync.calls.isEmpty)
        }
        v.setClient(ClientSelection(live))
        #expect(v.saveDraft())
        let id = v.quoteId
        try ClientStore(context: ctx, sync: sync, userId: "u1", profileId: "p1").delete(id: live.id)
        let loaded = vm(ctx, sync); loaded.load(id: id)
        #expect(loaded.clientId == live.id && loaded.saveDraft())
    }

    @Test func saveFailureDoesNotEnqueueDraft() throws {
        let (ctx, sync) = try makeFixture()
        struct Failure: Error {}
        let v = QuoteEditorViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1", persist: { _ in throw Failure() })
        v.load(id: nil); v.setClient(name: "Acme", email: nil)
        #expect(v.saveDraft() == false)
        #expect(v.errorMessage != nil && sync.calls.isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<Quote>()).isEmpty)
    }

    @Test func failedExistingDraftSaveRetainsInputAndUnrelatedChanges() throws {
        let (ctx, sync) = try makeFixture()
        let original = vm(ctx, sync)
        original.load(id: nil); original.setClient(name: "Saved", email: nil)
        original.addLine()
        original.lineItems[0].itemDescription = "Saved line"
        original.lineItems[0].unitPriceCents = 10_000
        #expect(original.saveDraft())
        let unrelated = Client(userId: "u1", profileId: "p1", name: "Other", notes: "Saved notes")
        ctx.insert(unrelated); try ctx.save()
        var shouldFail = true
        struct Failure: Error {}
        let v = QuoteEditorViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1", persist: { context in
            if shouldFail { throw Failure() }
            try context.save()
        })
        v.load(id: original.quoteId)
        v.setClient(name: "Typed", email: "typed@example.com")
        v.lineItems[0].itemDescription = "Typed description"
        v.lineItems[0].quantity = 3; v.lineItems[0].unitPriceCents = 20_000
        unrelated.notes = "Pending unrelated notes"
        sync.calls.removeAll()
        #expect(v.saveDraft() == false && v.errorMessage != nil)
        #expect(sync.calls.isEmpty)
        #expect(v.clientName == "Typed" && v.lineItems[0].itemDescription == "Typed description")
        #expect(v.lineItems[0].quantity == 3 && v.lineItems[0].unitPriceCents == 20_000)
        #expect(unrelated.notes == "Pending unrelated notes" && ctx.hasChanges)
        let reader = ModelContext(ctx.container)
        let saved = try #require(reader.fetch(FetchDescriptor<Quote>()).first)
        #expect(saved.clientName == "Saved" && saved.totalCents == 11_000)
        #expect(try reader.fetch(FetchDescriptor<QuoteLineItem>()).first?.unitPriceCents == 10_000)
        shouldFail = false
        #expect(v.saveDraft())
        #expect(v.lineItems[0].itemDescription == "Typed description" && v.totals.total == 66_000)
        let retried = ModelContext(ctx.container)
        let savedLine = try #require(retried.fetch(FetchDescriptor<QuoteLineItem>()).first)
        #expect(savedLine.itemDescription == "Typed description" && savedLine.quantity == 3 && savedLine.unitPriceCents == 20_000)
        #expect(try retried.fetch(FetchDescriptor<Client>()).first?.notes == "Saved notes")
        #expect(unrelated.notes == "Pending unrelated notes" && ctx.hasChanges)
        try ctx.save()
        #expect(try ModelContext(ctx.container).fetch(FetchDescriptor<Client>()).first?.notes == "Pending unrelated notes")
        #expect(sync.calls.contains { $0.entityType == .quoteLineItem && $0.entityId == v.lineItems[0].id })
    }

    @Test(arguments: [false, true])
    func failedDraftSaveRetainsNewLinesForRetry(existingDraft: Bool) throws {
        let (ctx, sync) = try makeFixture()
        var shouldFail = false
        struct Failure: Error {}
        let v = QuoteEditorViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1", persist: { context in
            if shouldFail { throw Failure() }
            try context.save()
        })
        v.load(id: nil); v.setClient(name: "Typed client", email: nil)
        var removedLine: QuoteLineItem?
        if existingDraft {
            v.addLine(); v.lineItems[0].unitPriceCents = 10_000
            #expect(v.saveDraft())
            removedLine = v.lineItems[0]
            v.removeLine(v.lineItems[0])
        }
        v.addLine()
        let newLine = v.lineItems[0]
        newLine.itemDescription = "Typed new line"
        newLine.quantity = 2; newLine.unitPriceCents = 5_000
        shouldFail = true; sync.calls.removeAll()
        #expect(v.saveDraft() == false && v.errorMessage != nil && sync.calls.isEmpty)
        #expect(newLine.itemDescription == "Typed new line" && newLine.quantity == 2 && newLine.unitPriceCents == 5_000)
        #expect(removedLine?.deletedAt == nil)
        // An unrelated later save must not persist a failed insert or deletion.
        let unrelated = Client(userId: "u1", profileId: "p1", name: "Other")
        ctx.insert(unrelated); try ctx.save()
        let reader = ModelContext(ctx.container)
        let beforeRetry = try reader.fetch(FetchDescriptor<QuoteLineItem>())
        #expect(beforeRetry.allSatisfy { $0.id != newLine.id && $0.deletedAt == nil })
        #expect(try reader.fetch(FetchDescriptor<Quote>()).count == (existingDraft ? 1 : 0))
        shouldFail = false
        #expect(v.saveDraft())
        let retried = ModelContext(ctx.container)
        let savedLines = try retried.fetch(FetchDescriptor<QuoteLineItem>())
        let savedLine = try #require(savedLines.first { $0.id == newLine.id })
        #expect(savedLine.itemDescription == "Typed new line" && savedLine.quantity == 2 && savedLine.unitPriceCents == 5_000 && savedLine.deletedAt == nil)
        if let removedLine {
            #expect(savedLines.first { $0.id == removedLine.id }?.deletedAt != nil)
            #expect(sync.calls.contains { $0.entityId == removedLine.id && $0.op == "delete" })
        }
        #expect(sync.calls.contains { $0.entityId == newLine.id && $0.op == "upsert" })
    }
}

@MainActor @Suite(.serialized) struct QuoteCatalogAtomicSaveTests {
    @Test(arguments: [false, true])
    func stagedOutboxFailureRetainsInputAndRetries(existing: Bool) throws {
        let context = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        context.autosaveEnabled = false
        let notes = Client(userId: "u1", profileId: "p1", name: "Other", notes: "Saved")
        context.insert(notes); try context.save()
        let engine = SyncEngine(api: MockAPIClient(), context: context, auth: AuthStore(), toast: ToastCenter())
        var fail = false, staged = 0
        enum Failure: Error { case save }
        let editor = QuoteEditorViewModel(context: context, sync: engine, userId: "u1", profileId: "p1", persist: { transaction in
            staged = try transaction.fetch(FetchDescriptor<OutboxMutation>()).count
            if fail { throw Failure.save }
            try transaction.save()
        })
        editor.load(id: nil); editor.setClient(name: "Typed client", email: "typed@test.com")
        var oldId: String?
        if existing {
            editor.addLine(); editor.lineItems[0].itemDescription = "Old"; editor.lineItems[0].unitPriceCents = 100
            #expect(editor.saveDraft())
            oldId = editor.lineItems[0].id; editor.removeLine(editor.lineItems[0])
        }
        let item = try CatalogStore(context: context, sync: engine, userId: "u1", profileId: "p1")
            .save(id: nil, description: "Saved service", unitLabel: "hour", unitPriceCents: 200)
        let lineId = try editor.addCatalogItem(item)
        editor.lineItems[0].itemDescription = "Typed service"
        editor.lineItems[0].unitLabel = "day"; editor.lineItems[0].quantity = 3
        notes.notes = "Pending"
        let baseline = ModelContext(context.container)
        let outboxBefore = try baseline.fetch(FetchDescriptor<OutboxMutation>()).map { $0.payloadJSON }.sorted()
        fail = true
        #expect(!editor.saveDraft() && editor.errorMessage != nil)
        #expect(staged == (existing ? 5 : 3))
        #expect(editor.lineItems[0].id == lineId && editor.lineItems[0].unitLabel == "day" && editor.lineItems[0].quantity == 3)
        let failed = ModelContext(context.container)
        #expect(try failed.fetch(FetchDescriptor<Quote>()).count == (existing ? 1 : 0))
        #expect(try failed.fetch(FetchDescriptor<Quote>()).first?.totalCents == (existing ? 110 : nil))
        #expect(try failed.fetch(FetchDescriptor<QuoteLineItem>()).count == (existing ? 1 : 0))
        #expect(try failed.fetch(FetchDescriptor<QuoteLineItem>()).allSatisfy { $0.deletedAt == nil && $0.itemDescription == "Old" })
        #expect(try failed.fetch(FetchDescriptor<OutboxMutation>()).map { $0.payloadJSON }.sorted() == outboxBefore)
        #expect(notes.notes == "Pending" && context.hasChanges)
        fail = false
        #expect(editor.saveDraft() && editor.errorMessage == nil)
        let retried = ModelContext(context.container)
        let saved = try #require(retried.fetch(FetchDescriptor<QuoteLineItem>()).first { $0.id == lineId })
        #expect(saved.itemDescription == "Typed service" && saved.unitLabel == "day" && saved.quantity == 3 && saved.unitPriceCents == 200)
        #expect(try retried.fetch(FetchDescriptor<OutboxMutation>()).first { $0.entityId == lineId }?.payloadJSON.contains("day") == true)
        if let oldId { #expect(try retried.fetch(FetchDescriptor<QuoteLineItem>()).first { $0.id == oldId }?.deletedAt != nil) }
        #expect(try retried.fetch(FetchDescriptor<Client>()).first?.notes == "Saved")
        try context.save()
        #expect(try ModelContext(context.container).fetch(FetchDescriptor<Client>()).first?.notes == "Pending")
        #expect(try ModelContext(context.container).fetch(FetchDescriptor<QuoteLineItem>()).first { $0.id == lineId }?.unitLabel == "day")
    }
    @Test func savedSnapshotRefreshesCachedParentForLaterActionWrites() throws {
        let context = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        context.autosaveEnabled = false
        let parent = Quote(userId: "u1", profileId: "p1", clientName: "Before")
        context.insert(parent); try context.save()
        let editor = QuoteEditorViewModel(context: context, sync: MockSyncEngine(), userId: "u1", profileId: "p1")
        editor.load(id: parent.id); editor.setClient(name: "After", email: "new@test.com")
        editor.addLine(); editor.lineItems[0].unitLabel = "hour"; editor.lineItems[0].unitPriceCents = 100
        #expect(editor.saveDraft())
        #expect(parent.clientName == "After" && parent.totalCents == 110)
        parent.number = "Issued-1"
        try context.save()
        let saved = try #require(ModelContext(context.container).fetch(FetchDescriptor<Quote>()).first)
        #expect(saved.clientName == "After" && saved.totalCents == 110 && saved.number == "Issued-1")
    }
    @Test func rejectsForeignAndDeletedSavedItems() throws {
        let context = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        let sync = MockSyncEngine()
        let editor = QuoteEditorViewModel(context: context, sync: sync, userId: "u1", profileId: "p1")
        editor.load(id: nil)
        for (user, profile, deleted) in [("u2", "p1", false), ("u1", "p2", false), ("u1", "p1", true)] {
            let item = CatalogItem(userId: user, profileId: profile, itemDescription: "Wrong", unitPriceCents: 10, deletedAt: deleted ? 1 : nil)
            context.insert(item); try context.save()
            #expect(throws: CatalogStore.ValidationError.self) { try editor.addCatalogItem(item) }
        }
        #expect(editor.lineItems.isEmpty)
    }
}
