import Foundation
import SwiftData
import Testing
@testable import Snapceipt

@MainActor
@Suite("Document GST rate snapshot survives profile change")
struct DocumentRateSnapshotTests {
    @Test("quote saved at 15% keeps 15% after profile flips to 10%")
    func snapshotSurvives() throws {
        let c = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        let p = Profile(userId: "u1", name: "Biz", type: "business",
                        accent1: "#0E7C72", accent2: "#DCF0ED", accent3: "#0A5950",
                        gstRateBp: 1500)
        p.id = "p1"
        c.insert(p); try c.save()

        let vm = QuoteEditorViewModel(context: c, sync: MockSyncEngine(), userId: "u1", profileId: "p1")
        vm.load(id: nil)
        vm.setClient(name: "Acme", email: nil)
        vm.addLine()
        vm.lineItems[0].itemDescription = "Work"
        vm.lineItems[0].unitPriceCents = 20_000
        vm.saveDraft()

        let q = try c.fetch(FetchDescriptor<Quote>())[0]
        #expect(q.gstRateBp == 1500)
        let qid = q.id

        // Profile rate later changes to 10%.
        p.gstRateBp = 1000
        try c.save()

        // Re-open the quote in a fresh VM — it must still total at 15%.
        let vm2 = QuoteEditorViewModel(context: c, sync: MockSyncEngine(), userId: "u1", profileId: "p1")
        vm2.load(id: qid)
        #expect(vm2.totals.gst == 3_000)   // 200.00 @ 15%, NOT 20.00 @ 10%
        vm2.saveDraft()
        #expect(try c.fetch(FetchDescriptor<Quote>())[0].gstRateBp == 1500)
    }
}
