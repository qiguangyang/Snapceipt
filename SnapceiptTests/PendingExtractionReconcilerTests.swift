import Testing
import SwiftData
import Foundation
@testable import Snapceipt

@MainActor
struct PendingExtractionReconcilerTests {
    @MainActor final class SpySync: SyncEnqueuing {
        private(set) var enqueuedTxnIds: [String] = []
        func enqueue(op: String, entityType: EntityType, entity: any Syncable) {
            if entityType == .transaction { enqueuedTxnIds.append(entity.id) }
        }
    }

    private func fixture() throws -> (ModelContext, MockAPIClient, SpySync) {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        return (ModelContext(container), MockAPIClient(), SpySync())
    }

    private func okResponse(category: String, gst: String, deductible: Int) -> ExtractionResponse {
        let json = """
        {"requestId":"r","receipt":{"merchant":"M","date":"2026-05-28","currencyCode":"AUD",
          "total":20.00,"gst":\(gst),"category":"\(category)","deductible":\(deductible),
          "lineItems":[],"confidence":0.95,"needsReview":false},
         "meta":{"model":"x","source":"scan","latencyMs":1,"attempts":1,"stub":false}}
        """
        return try! JSONDecoder().decode(ExtractionResponse.self, from: Data(json.utf8))
    }

    private func seedPending(_ ctx: ModelContext) throws -> Transaction {
        let txn = Transaction(userId: "u1", profileId: "p1", catKey: "office",
                              amountCents: -2000, txnDate: "2026-05-28",
                              source: "scan", extractionStatus: "pending")
        let pr = PendingReceipt(transactionId: txn.id, ocrText: "M\nTOTAL 20.00",
                                imageLocalPath: "/tmp/x.jpg", width: 1, height: 1)
        ctx.insert(txn); ctx.insert(pr); try ctx.save()
        return txn
    }

    @Test("a pending scan re-extracts, updates fields, marks done, re-enqueues the upsert")
    func reExtractsToDone() async throws {
        let (ctx, api, sync) = try fixture()
        let txn = try seedPending(ctx)
        api.extractHandler = { _, _, _ in self.okResponse(category: "meals", gst: "1.82", deductible: 50) }
        let r = PendingExtractionReconciler(api: api, context: ctx, sync: sync)
        await r.reconcile()
        let updated = try ctx.fetch(FetchDescriptor<Transaction>()).first { $0.id == txn.id }!
        #expect(updated.extractionStatus == "done")
        #expect(updated.catKey == "meals")
        #expect(updated.gstCents == 182)
        #expect(updated.deductiblePct == 50)
        #expect(updated.isAi == true)
        #expect(sync.enqueuedTxnIds == [txn.id])
    }

    @Test("after maxExtractionAttempts the scan is marked failed and not re-enqueued")
    func boundedToFailed() async throws {
        struct Boom: Error {}
        let (ctx, api, sync) = try fixture()
        let txn = Transaction(userId: "u1", profileId: "p1", catKey: "office",
                              amountCents: -2000, txnDate: "2026-05-28",
                              source: "scan", extractionStatus: "pending")
        let pr = PendingReceipt(transactionId: txn.id, ocrText: "M\nTOTAL 20.00",
                                imageLocalPath: "/tmp/x.jpg", width: 1, height: 1, extractionAttempts: 2)
        ctx.insert(txn); ctx.insert(pr); try ctx.save()
        api.extractHandler = { _, _, _ in throw Boom() }
        let r = PendingExtractionReconciler(api: api, context: ctx, sync: sync)
        await r.reconcile()
        let updated = try ctx.fetch(FetchDescriptor<Transaction>()).first { $0.id == txn.id }!
        #expect(updated.extractionStatus == "failed")
        #expect(sync.enqueuedTxnIds.isEmpty)
    }
}
