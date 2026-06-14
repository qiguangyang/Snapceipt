import Foundation
import SwiftData
import os

/// Upgrades transactions saved via the offline heuristic fallback. Finds scan txns
/// stuck at `extractionStatus=="pending"` with an available OCR text, re-calls
/// `/extract`, updates the derived fields, marks them `done`, and re-enqueues the
/// upsert. After 3 attempts a txn is marked `failed` and dropped. Bounded per pass.
@MainActor
final class PendingExtractionReconciler {
    private let api: APIClient
    private let context: ModelContext
    private let sync: any SyncEnqueuing
    private let maxExtractionAttempts = 3
    private let maxPerPass = 5
    private let log = Logger(subsystem: "app.snapceipt", category: "reconciler")

    init(api: APIClient, context: ModelContext, sync: any SyncEnqueuing) {
        self.api = api
        self.context = context
        self.sync = sync
    }

    func reconcile() async {
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate {
                $0.source == "scan" && $0.extractionStatus == "pending"
            },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        let pendingTxns = (try? context.fetch(descriptor)) ?? []
        if pendingTxns.count > maxPerPass {
            log.info("reconciler capped: \(pendingTxns.count) pending, processing \(self.maxPerPass)")
        }
        for txn in pendingTxns.prefix(maxPerPass) {
            guard let receipt = pendingReceipt(for: txn.id) else { continue }
            await reconcileOne(txn, receipt)
        }
    }

    private func reconcileOne(_ txn: Transaction, _ receipt: PendingReceipt) async {
        receipt.extractionAttempts += 1
        do {
            let resp = try await api.extract(ocrText: receipt.ocrText, source: "scan",
                                             capturedAt: txn.txnDate)
            let r = resp.receipt
            txn.catKey = r.categoryKey
            txn.gstCents = r.gst.map(ReceiptMapper.cents)
            txn.gstSource = r.gst != nil ? "printed" : nil
            txn.deductiblePct = r.deductible
            txn.isAi = true
            txn.extractionStatus = "done"
            txn.updatedAt = Epoch.nowMs()
            try? context.save()
            sync.enqueue(op: "upsert", entityType: .transaction, entity: txn)
        } catch {
            if receipt.extractionAttempts >= maxExtractionAttempts {
                txn.extractionStatus = "failed"
            }
            try? context.save()
        }
    }

    private func pendingReceipt(for transactionId: String) -> PendingReceipt? {
        let descriptor = FetchDescriptor<PendingReceipt>(
            predicate: #Predicate { $0.transactionId == transactionId }
        )
        return (try? context.fetch(descriptor))?.first
    }
}
