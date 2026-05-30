import Foundation
import SwiftData

/// Drains `PendingReceipt` image uploads on reconnect/foreground. Gates each upload
/// on the parent transaction's outbox mutation being applied (no pending/inflight
/// `OutboxMutation` for that id), so the server row exists before the image links.
/// Claims each row as `"inflight"` (saved) before the network await so a concurrent
/// `drain()` (which only selects `"pending"` rows) cannot re-upload it. On success:
/// `uploadState="done"` + delete the local JPEG. On failure: reset to `"pending"` to
/// retry, or `"failed"` after 3 attempts.
@MainActor
final class ReceiptUploadQueue {
    private let api: APIClient
    private let context: ModelContext
    private let maxUploadAttempts = 3

    init(api: APIClient, context: ModelContext) {
        self.api = api
        self.context = context
    }

    /// Process all `pending` receipts whose parent txn has been applied.
    func drain() async {
        let descriptor = FetchDescriptor<PendingReceipt>(
            predicate: #Predicate { $0.uploadState == "pending" },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        let pending = (try? context.fetch(descriptor)) ?? []
        for receipt in pending {
            guard txnApplied(receipt.transactionId) else { continue }
            await upload(receipt)
        }
    }

    /// True when there is no pending/inflight outbox mutation for the txn id.
    private func txnApplied(_ transactionId: String) -> Bool {
        let descriptor = FetchDescriptor<OutboxMutation>(
            predicate: #Predicate {
                $0.entityId == transactionId
                && ($0.status == "pending" || $0.status == "inflight")
            }
        )
        return ((try? context.fetchCount(descriptor)) ?? 0) == 0
    }

    private func upload(_ receipt: PendingReceipt) async {
        guard let jpeg = FileManager.default.contents(atPath: receipt.imageLocalPath) else {
            receipt.uploadState = "done"   // file gone — nothing to upload; let cleanup reclaim it
            try? context.save()
            return
        }
        receipt.uploadAttempts += 1
        receipt.uploadState = "inflight"   // claim it so a concurrent drain skips it
        try? context.save()
        do {
            _ = try await api.uploadImage(jpeg: jpeg, transactionId: receipt.transactionId,
                                          width: receipt.width, height: receipt.height)
            receipt.uploadState = "done"
            try? FileManager.default.removeItem(atPath: receipt.imageLocalPath)
        } catch {
            receipt.uploadState = receipt.uploadAttempts >= maxUploadAttempts ? "failed" : "pending"
        }
        try? context.save()
    }
}
