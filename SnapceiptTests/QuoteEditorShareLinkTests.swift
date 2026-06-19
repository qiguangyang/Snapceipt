import Foundation
import SwiftData
import Testing
@testable import Snapceipt

@MainActor
@Suite("Quote editor share link + rate snapshot")
struct QuoteEditorShareLinkTests {
    private func makeVM() throws -> (QuoteEditorViewModel, ModelContext) {
        let c = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        // Active business profile at 15%.
        let p = Profile(userId: "u1", name: "Biz", type: "business",
                        accent1: "#0E7C72", accent2: "#DCF0ED", accent3: "#0A5950",
                        gstRateBp: 1500)
        p.id = "p1"
        c.insert(p); try c.save()
        let vm = QuoteEditorViewModel(context: c, sync: MockSyncEngine(), userId: "u1", profileId: "p1")
        vm.load(id: nil)
        vm.setClient(name: "Acme", email: "a@acme.au")
        vm.addLine()
        vm.lineItems[0].itemDescription = "Work"
        vm.lineItems[0].quantity = 1
        vm.lineItems[0].unitPriceCents = 20_000
        return (vm, c)
    }

    @Test("saveDraft snapshots gstRateBp from the active profile + totals use it")
    func snapshotRate() throws {
        let (vm, c) = try makeVM()
        vm.saveDraft()
        let q = try c.fetch(FetchDescriptor<Quote>())[0]
        #expect(q.gstRateBp == 1500)
        // 200.00 @ 15% exclusive → gst 30.00, total 230.00
        #expect(q.gstCents == 3_000)
        #expect(q.totalCents == 23_000)
        #expect(vm.totals.gst == 3_000)
    }

    @Test("shareLink returns the url from the API and applies the minted number")
    func shareLink() async throws {
        let (vm, _) = try makeVM()
        let mock = MockAPIClient()
        mock.quoteShareLinkHandler = { _ in
            QuoteShareLinkResponse(url: "https://api.snapceipt.cc/q/tok", number: "SN-0001")
        }
        let url = await vm.shareLink(api: mock)
        #expect(url == "https://api.snapceipt.cc/q/tok")
        #expect(mock.quoteShareLinkCalls.count == 1)
        // The minted number is applied to the VM so "Quote #N" shows immediately.
        #expect(vm.number == "SN-0001")
    }

    @Test("send reads {url, emailed, number} — does NOT reference status/subtotalCents/gstCents/totalCents")
    func send() async throws {
        let (vm, _) = try makeVM()
        let mock = MockAPIClient()
        mock.sendQuoteHandler = { _ in
            SendQuoteResponse(url: "https://api.snapceipt.cc/q/tok", emailed: true,
                              number: "SN-0001")
        }
        let ok = await vm.send(api: mock)
        #expect(ok)
        #expect(vm.pdfUrl == "https://api.snapceipt.cc/q/tok")
        #expect(vm.emailed == true)
        // The minted number is applied immediately (no sync pull needed).
        #expect(vm.number == "SN-0001")
    }
}
