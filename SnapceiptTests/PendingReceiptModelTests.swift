import Testing
import SwiftData
@testable import Snapceipt

@MainActor
struct PendingReceiptModelTests {
    @Test("PendingReceipt persists in the app container and round-trips")
    func persistsInAppContainer() throws {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        let ctx = ModelContext(container)
        let pr = PendingReceipt(transactionId: "t1", ocrText: "TOTAL 5.00",
                                imageLocalPath: "/tmp/x.jpg", width: 1000, height: 1400)
        ctx.insert(pr)
        try ctx.save()
        let rows = try ctx.fetch(FetchDescriptor<PendingReceipt>())
        #expect(rows.count == 1)
        #expect(rows[0].transactionId == "t1")
        #expect(rows[0].uploadState == "pending")
        #expect(rows[0].uploadAttempts == 0)
        #expect(rows[0].extractionAttempts == 0)
    }

    @Test("PendingReceipt is registered in the schema")
    func isRegistered() {
        // `SnapceiptSchema.models` is `[any PersistentModel.Type]`; existential
        // metatypes have no `==`, so compare identities via ObjectIdentifier.
        #expect(SnapceiptSchema.models.contains { ObjectIdentifier($0) == ObjectIdentifier(PendingReceipt.self) })
    }
}
