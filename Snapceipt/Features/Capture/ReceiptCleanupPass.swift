import Foundation
import SwiftData

/// Reclaims `PendingReceipt` rows once they are terminal on BOTH axes: the upload is
/// done/failed AND the parent transaction's extraction is no longer pending. Deletes the
/// row (clearing the retained OCR text) and removes any leftover local JPEG. Runs last
/// in the capture drain pass.
@MainActor
final class ReceiptCleanupPass {
    private let context: ModelContext
    init(context: ModelContext) { self.context = context }

    func run() {
        let descriptor = FetchDescriptor<PendingReceipt>(
            predicate: #Predicate { $0.uploadState != "pending" && $0.uploadState != "inflight" }
        )
        let candidates = (try? context.fetch(descriptor)) ?? []
        for receipt in candidates {
            guard extractionTerminal(receipt.transactionId) else { continue }
            try? FileManager.default.removeItem(atPath: receipt.imageLocalPath)
            context.delete(receipt)
        }
        try? context.save()
    }

    /// True when the parent txn is gone or its extraction is no longer pending.
    private func extractionTerminal(_ transactionId: String) -> Bool {
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.id == transactionId && $0.extractionStatus == "pending" }
        )
        return ((try? context.fetchCount(descriptor)) ?? 0) == 0
    }
}
