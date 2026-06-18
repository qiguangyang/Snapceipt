import Foundation
import SwiftData

/// Reconciles the manual-entry line-item drafts against what's stored: updates
/// kept rows in place, inserts new rows, soft-deletes removed rows, and enqueues
/// each for sync. Returns the surviving ids (the caller's new `originalIds`).
/// Mirrors the quote editor's per-line diff (`QuoteEditorViewModel.saveDraft`).
@MainActor
enum ManualItemsReconciler {

    @discardableResult
    static func reconcile(
        drafts: [ItemDraft],
        originalIds: Set<String>,
        txnId: String,
        userId: String,
        context: ModelContext,
        sync: any SyncEnqueuing
    ) -> Set<String> {
        let desired = ManualItemsMapper.lineItems(from: drafts, txnId: txnId, userId: userId)
        let keptIds = Set(desired.map(\.id))

        // Upsert: update an existing row in place, else insert the new one.
        var upserts: [LineItem] = []
        for item in desired {
            if let existing = fetch(item.id, context) {
                existing.name = item.name
                existing.priceCents = item.priceCents
                existing.quantity = item.quantity
                existing.sortOrder = item.sortOrder
                existing.updatedAt = Epoch.nowMs()
                upserts.append(existing)
            } else {
                context.insert(item)
                upserts.append(item)
            }
        }

        // Soft-delete rows that were loaded but are gone from the draft set.
        var deleted: [LineItem] = []
        for rid in originalIds.subtracting(keptIds) {
            if let row = fetch(rid, context) {
                row.deletedAt = Epoch.nowMs()
                row.updatedAt = Epoch.nowMs()
                deleted.append(row)
            }
        }

        try? context.save()

        for item in upserts { sync.enqueue(op: "upsert", entityType: .lineItem, entity: item) }
        for row in deleted { sync.enqueue(op: "delete", entityType: .lineItem, entity: row) }

        return keptIds
    }

    private static func fetch(_ id: String, _ context: ModelContext) -> LineItem? {
        var d = FetchDescriptor<LineItem>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }
}
