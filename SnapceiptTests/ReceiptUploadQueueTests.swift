import Testing
import SwiftData
import Foundation
@testable import Snapceipt

@MainActor
struct ReceiptUploadQueueTests {
    private func tempJPEG() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: url)
        return url.path
    }

    private func fixture() throws -> (ModelContext, MockAPIClient) {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        return (ModelContext(container), MockAPIClient())
    }

    @Test("uploads a pending receipt whose txn has no outstanding outbox mutation; marks done + deletes file")
    func uploadsWhenTxnApplied() async throws {
        let (ctx, api) = try fixture()
        let path = try tempJPEG()
        let pr = PendingReceipt(transactionId: "t1", ocrText: "x", imageLocalPath: path,
                                width: 100, height: 140)
        ctx.insert(pr); try ctx.save()
        api.uploadImageHandler = { _, txnId, w, h in
            #expect(txnId == "t1"); #expect(w == 100); #expect(h == 140)
            return UploadedImage(imageKey: "u/u1/a.jpg", getUrl: "/images/u/u1/a.jpg", byteSize: 3)
        }
        let queue = ReceiptUploadQueue(api: api, context: ctx)
        await queue.drain()
        let rows = try ctx.fetch(FetchDescriptor<PendingReceipt>())
        #expect(rows[0].uploadState == "done")
        #expect(api.uploadCalls.count == 1)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("skips a receipt whose txn still has a pending outbox mutation")
    func skipsWhenTxnNotApplied() async throws {
        let (ctx, api) = try fixture()
        let pr = PendingReceipt(transactionId: "t2", ocrText: "x", imageLocalPath: try tempJPEG(),
                                width: 1, height: 1)
        let mutation = OutboxMutation(entityType: "transaction", entityId: "t2", op: "upsert",
                                      payloadJSON: "{}", status: "pending")
        ctx.insert(pr); ctx.insert(mutation); try ctx.save()
        let queue = ReceiptUploadQueue(api: api, context: ctx)
        await queue.drain()
        #expect(api.uploadCalls.isEmpty)
        let rows = try ctx.fetch(FetchDescriptor<PendingReceipt>())
        #expect(rows[0].uploadState == "pending")
    }

    @Test("after maxUploadAttempts failures the receipt is marked failed")
    func failsAfterMaxAttempts() async throws {
        struct Boom: Error {}
        let (ctx, api) = try fixture()
        let pr = PendingReceipt(transactionId: "t3", ocrText: "x", imageLocalPath: try tempJPEG(),
                                width: 1, height: 1, uploadAttempts: 2)
        ctx.insert(pr); try ctx.save()
        api.uploadImageHandler = { _, _, _, _ in throw Boom() }
        let queue = ReceiptUploadQueue(api: api, context: ctx)
        await queue.drain()
        let rows = try ctx.fetch(FetchDescriptor<PendingReceipt>())
        #expect(rows[0].uploadState == "failed")
        #expect(rows[0].uploadAttempts == 3)
    }
}
