import Foundation
import SwiftData

struct CatalogItemSyncMapper: SyncRowMapper {
    func upsert(_ context: ModelContext, _ env: PullChange) {
        let row = fetch(context, env.id) ?? {
            let row = CatalogItem(id: env.id, userId: env.userId, profileId: env.profileId ?? "")
            context.insert(row)
            return row
        }()
        applySharedEnvelope(row, env)
        row.profileId = env.profileId
        if let value = env.string("itemDescription") { row.itemDescription = value }
        if env.raw["unitLabel"] != nil { row.unitLabel = env.string("unitLabel") }
        if let value = env.int("unitPriceCents") { row.unitPriceCents = value }
        if let value = env.string("currency") { row.currency = value }
    }

    func payload(_ row: CatalogItem) -> [String: JSONValue] {
        var fields = sharedFields(row)
        fields["itemDescription"] = .string(row.itemDescription)
        fields["unitLabel"] = str(row.unitLabel)
        fields["unitPriceCents"] = num(row.unitPriceCents)
        fields["currency"] = .string(row.currency)
        return fields
    }
}

struct ClientFollowUpSyncMapper: SyncRowMapper {
    func upsert(_ context: ModelContext, _ env: PullChange) {
        let row = fetch(context, env.id) ?? {
            let row = ClientFollowUp(id: env.id, userId: env.userId, profileId: env.profileId ?? "")
            context.insert(row)
            return row
        }()
        applySharedEnvelope(row, env)
        row.profileId = env.profileId
        if let value = env.string("clientId") { row.clientId = value }
        if let value = env.string("title") { row.title = value }
        if let value = env.int("dueAt") { row.dueAt = value }
        if let value = env.string("timezone") { row.timezone = value }
        if env.raw["completedAt"] != nil { row.completedAt = env.int("completedAt") }
    }

    func payload(_ row: ClientFollowUp) -> [String: JSONValue] {
        var fields = sharedFields(row)
        fields["clientId"] = .string(row.clientId)
        fields["title"] = .string(row.title)
        fields["dueAt"] = num(row.dueAt)
        fields["timezone"] = .string(row.timezone)
        fields["completedAt"] = num(row.completedAt)
        return fields
    }
}

extension CatalogItem: SyncableMutableEnvelope, MutableSyncRow {
    func setRev(_ rev: Int) { self.rev = rev }
    func setUpdatedAt(_ updatedAt: Int) { self.updatedAt = updatedAt }
}

extension ClientFollowUp: SyncableMutableEnvelope, MutableSyncRow {
    func setRev(_ rev: Int) { self.rev = rev }
    func setUpdatedAt(_ updatedAt: Int) { self.updatedAt = updatedAt }
}
