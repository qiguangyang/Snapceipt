import Testing
import SwiftData
import Foundation
@testable import Snapceipt

@MainActor
struct ReceiptCleanupPassTests {
    private func tempJPEG() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: url)
        return url.path
    }

    private func context() throws -> ModelContext {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        return ModelContext(container)
    }

    private func txn(id: String, extractionStatus: String?) -> Transaction {
        Transaction(id: id, userId: "u1", profileId: "p1", catKey: "meals",
                    amountCents: -100, txnDate: "2026-05-30", source: "scan",
                    extractionStatus: extractionStatus)
    }

    @Test("done receipt with done extraction is deleted and its JPEG removed")
    func deletesTerminalReceipt() throws {
        let ctx = try context()
        let path = try tempJPEG()
        let pr = PendingReceipt(transactionId: "t1", ocrText: "secret ocr", imageLocalPath: path,
                                width: 1, height: 1, uploadState: "done")
        ctx.insert(txn(id: "t1", extractionStatus: "done"))
        ctx.insert(pr); try ctx.save()

        ReceiptCleanupPass(context: ctx).run()

        let rows = try ctx.fetchCount(FetchDescriptor<PendingReceipt>())
        #expect(rows == 0)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("pending upload is not reclaimed")
    func keepsPendingUpload() throws {
        let ctx = try context()
        let pr = PendingReceipt(transactionId: "t2", ocrText: "x", imageLocalPath: try tempJPEG(),
                                width: 1, height: 1, uploadState: "pending")
        ctx.insert(txn(id: "t2", extractionStatus: "done"))
        ctx.insert(pr); try ctx.save()

        ReceiptCleanupPass(context: ctx).run()

        #expect(try ctx.fetchCount(FetchDescriptor<PendingReceipt>()) == 1)
    }

    @Test("failed upload with still-pending extraction is not reclaimed")
    func keepsWhenExtractionPending() throws {
        let ctx = try context()
        let pr = PendingReceipt(transactionId: "t3", ocrText: "x", imageLocalPath: try tempJPEG(),
                                width: 1, height: 1, uploadState: "failed")
        ctx.insert(txn(id: "t3", extractionStatus: "pending"))
        ctx.insert(pr); try ctx.save()

        ReceiptCleanupPass(context: ctx).run()

        #expect(try ctx.fetchCount(FetchDescriptor<PendingReceipt>()) == 1)
    }

    @Test("done receipt orphaned from a deleted txn is reclaimed")
    func deletesOrphan() throws {
        let ctx = try context()
        let pr = PendingReceipt(transactionId: "gone", ocrText: "x", imageLocalPath: try tempJPEG(),
                                width: 1, height: 1, uploadState: "done")
        ctx.insert(pr); try ctx.save()   // no matching Transaction inserted

        ReceiptCleanupPass(context: ctx).run()

        #expect(try ctx.fetchCount(FetchDescriptor<PendingReceipt>()) == 0)
    }
}
