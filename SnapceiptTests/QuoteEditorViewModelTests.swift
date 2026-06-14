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
        #expect(v.quoteId != nil)
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

    @Test("send flushes the outbox BEFORE calling sendQuote (the quote must exist server-side)")
    func sendFlushesBeforeSending() async throws {
        let (ctx, sync) = try makeFixture()
        let mock = MockAPIClient()
        // Capture how many flushes had completed at the moment sendQuote is invoked —
        // proves the outbox was drained (flushCount == 1) before the send call fires.
        var flushCountAtSend = -1
        mock.sendQuoteHandler = { _ in
            flushCountAtSend = sync.flushCount
            return SendQuoteResponse(number: "SN-0001", sentAt: 1, status: "sent",
                                     subtotalCents: 10_00, gstCents: 1_00, totalCents: 11_00,
                                     pdfUrl: "/quotes/dl/tok", expiresAt: 1, emailed: false)
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
}
