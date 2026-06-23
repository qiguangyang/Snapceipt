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

    @Test("a REVIEWED pending scan (autoSaved=false) keeps merchant/total — only enriches classification")
    func reviewedKeepsUserValues() async throws {
        let (ctx, api, sync) = try fixture()
        // Reviewed placeholder: the user saw "Corner Cafe" / $1.23 on Review before saving.
        let txn = Transaction(userId: "u1", profileId: "p1", merchant: "Corner Cafe", catKey: "office",
                              amountCents: -123, txnDate: "2026-05-28",
                              source: "scan", extractionStatus: "pending")
        let pr = PendingReceipt(transactionId: txn.id, ocrText: "Corner Cafe\nTOTAL 1.23",
                                imageLocalPath: "/tmp/x.jpg", width: 1, height: 1, autoSaved: false)
        ctx.insert(txn); ctx.insert(pr); try ctx.save()
        api.extractHandler = { _, _, _ in self.okResponse(category: "meals", gst: "0.11", deductible: 50) }
        await PendingExtractionReconciler(api: api, context: ctx, sync: sync).reconcile()
        let updated = try ctx.fetch(FetchDescriptor<Transaction>()).first { $0.id == txn.id }!
        #expect(updated.extractionStatus == "done")
        #expect(updated.catKey == "meals")          // enriched
        #expect(updated.gstCents == 11)             // enriched
        #expect(updated.deductiblePct == 50)        // enriched
        #expect(updated.isAi == true)
        // Preserved — the user reviewed these, so the AI result must NOT stomp them.
        #expect(updated.merchant == "Corner Cafe")
        #expect(updated.amountCents == -123)
    }

    @Test("an AUTO-SAVED pending scan (never reviewed) is FULLY replaced by the AI result")
    func autoSavedFullyReplaced() async throws {
        let (ctx, api, sync) = try fixture()
        // Auto-saved on exit: on-device placeholder the user never saw. merchant/total are
        // the heuristic's guess and SHOULD be overwritten by the AI result.
        let txn = Transaction(userId: "u1", profileId: "p1", merchant: "??", catKey: "office",
                              amountCents: -999, txnDate: "2020-01-01",
                              source: "scan", extractionStatus: "pending")
        let pr = PendingReceipt(transactionId: txn.id, ocrText: "M\nTOTAL 20.00",
                                imageLocalPath: "/tmp/x.jpg", width: 1, height: 1, autoSaved: true)
        ctx.insert(txn); ctx.insert(pr); try ctx.save()
        api.extractHandler = { _, _, _ in self.okResponse(category: "meals", gst: "1.82", deductible: 50) }
        await PendingExtractionReconciler(api: api, context: ctx, sync: sync).reconcile()
        let updated = try ctx.fetch(FetchDescriptor<Transaction>()).first { $0.id == txn.id }!
        #expect(updated.extractionStatus == "done")
        #expect(updated.merchant == "M")            // okResponse merchant
        #expect(updated.amountCents == -2000)       // total 20.00, meals = expense (negative)
        #expect(updated.txnDate == "2026-05-28")    // okResponse date
        #expect(updated.catKey == "meals")
        #expect(updated.gstCents == 182)
        #expect(updated.isAi == true)
    }

    @Test("a queued pending receipt (autoSaved) is fully replaced by the cloud result")
    func queuedFullyReplaced() async throws {
        let (ctx, api, sync) = try fixture()
        // Sentinel txnDate ("1970-01-01") proves the post-replace date was overwritten.
        let txn = Transaction(userId: "u1", profileId: "p1", merchant: "", catKey: "office",
                              amountCents: 0, txnDate: "1970-01-01", source: "scan", extractionStatus: "pending")
        let pr = PendingReceipt(transactionId: txn.id, ocrText: "M\nTOTAL 20.00",
                                imageLocalPath: "/tmp/x.jpg", width: 1, height: 1, autoSaved: true)
        ctx.insert(txn); ctx.insert(pr); try ctx.save()
        api.extractHandler = { _,_,_ in self.okResponse(category: "meals", gst: "1.82", deductible: 50) }
        await PendingExtractionReconciler(api: api, context: ctx, sync: sync).reconcile()
        let u = try ctx.fetch(FetchDescriptor<Transaction>()).first { $0.id == txn.id }!
        #expect(u.extractionStatus == "done")   // reconciler ran to completion
        #expect(u.merchant == "M")              // full replace
        #expect(u.amountCents == -2000)
        #expect(u.txnDate == "2026-05-28")      // okResponse date overwrote the sentinel
        #expect(u.catKey == "meals")            // okResponse category
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
