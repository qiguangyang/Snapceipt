import Foundation
import SwiftData

/// Scoped saved-item writes commit the item and its outbox in one isolated save.
@MainActor
final class CatalogStore {
    enum ValidationError: LocalizedError {
        case blankDescription, descriptionTooLong, unitTooLong, unavailable
        var errorDescription: String? {
            switch self {
            case .blankDescription: "Enter a description."
            case .descriptionTooLong: "Description must be 500 characters or fewer."
            case .unitTooLong: "Unit must be 40 characters or fewer."
            case .unavailable: "This saved item is no longer available in this business."
            }
        }
    }
    private let context: ModelContext
    private let sync: any SyncEnqueuing
    private let userId: String
    private let profileId: String
    private let persist: (ModelContext) throws -> Void

    init(context: ModelContext, sync: any SyncEnqueuing, userId: String, profileId: String,
         persist: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.context = context; self.sync = sync; self.userId = userId
        self.profileId = profileId; self.persist = persist
    }

    func list(search: String) throws -> [CatalogItem] {
        let uid = userId, pid = profileId
        let items = try context.fetch(FetchDescriptor<CatalogItem>(predicate: #Predicate {
            $0.userId == uid && $0.profileId == pid && $0.deletedAt == nil
        }, sortBy: [SortDescriptor(\.itemDescription), SortDescriptor(\.createdAt)]))
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? items : items.filter { $0.itemDescription.localizedCaseInsensitiveContains(query) }
    }

    func save(id: String?, description: String, unitLabel: String?, unitPriceCents: Int) throws -> CatalogItem {
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = unitLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { throw ValidationError.blankDescription }
        guard description.utf16.count <= 500 else { throw ValidationError.descriptionTooLong }
        guard (unit?.utf16.count ?? 0) <= 40 else { throw ValidationError.unitTooLong }
        _ = try CatalogPrice.enteredCents(exclusiveCents: unitPriceCents, gstEnabled: false, gstInclusive: false, rateBp: 0)
        let mutationContext = ModelContext(context.container)
        mutationContext.autosaveEnabled = false
        let item: CatalogItem
        if let id { item = try liveItem(id: id, in: mutationContext) }
        else {
            item = CatalogItem(userId: userId, profileId: profileId,
                               currency: AppSettings.businessCurrency(profileId: profileId))
            mutationContext.insert(item)
        }
        item.itemDescription = description
        item.unitLabel = (unit?.isEmpty ?? true) ? nil : unit
        item.unitPriceCents = unitPriceCents; item.updatedAt = Epoch.nowMs()
        try sync.persistAndEnqueue(mutations: [.init(op: "upsert", entityType: .catalogItem, entity: item)],
                                   context: mutationContext, save: persist)
        if let id, let working = try? liveItem(id: id, in: context) {
            working.itemDescription = item.itemDescription; working.unitLabel = item.unitLabel
            working.unitPriceCents = item.unitPriceCents; working.updatedAt = item.updatedAt
            return working
        }
        return item
    }

    func delete(id: String) throws {
        let mutationContext = ModelContext(context.container)
        mutationContext.autosaveEnabled = false
        let item = try liveItem(id: id, in: mutationContext)
        let working = try liveItem(id: id, in: context)
        let now = Epoch.nowMs()
        item.deletedAt = now; item.updatedAt = now
        try sync.persistAndEnqueue(mutations: [.init(op: "delete", entityType: .catalogItem, entity: item)],
                                   context: mutationContext, save: persist)
        working.deletedAt = now; working.updatedAt = now
    }

    /// Recheck both the supplied object and durable ownership/liveness before insertion.
    func ownedItem(_ item: CatalogItem) throws -> CatalogItem {
        guard item.userId == userId, item.profileId == profileId, item.deletedAt == nil else { throw ValidationError.unavailable }
        return try liveItem(id: item.id, in: ModelContext(context.container))
    }

    private func liveItem(id: String, in context: ModelContext) throws -> CatalogItem {
        let uid = userId, pid = profileId
        let descriptor = FetchDescriptor<CatalogItem>(predicate: #Predicate {
            $0.id == id && $0.userId == uid && $0.profileId == pid && $0.deletedAt == nil
        })
        guard let item = try context.fetch(descriptor).first,
              item.userId == uid, item.profileId == pid, item.deletedAt == nil else { throw ValidationError.unavailable }
        return item
    }
}
