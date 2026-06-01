import Foundation
import SwiftData

/// A line on a quote, owned by its parent Quote. Mirrors D1 `quote_line_items`.
/// `lineTotalCents` is server-generated (quantity * unitPriceCents) — computed locally,
/// not a synced/stored field.
@Model
final class QuoteLineItem: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?           // always nil (child of a quote)

    var quoteId: String
    var itemDescription: String      // maps to backend "description"
    var quantity: Int
    var unitPriceCents: Int
    var sortOrder: Int

    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var rev: Int
    var lastEditedDeviceId: String?

    var entityType: EntityType { .quoteLineItem }

    /// Server-generated `line_total_cents` mirror; never persisted as a sync field.
    var lineTotalCents: Int { quantity * unitPriceCents }

    init(
        id: String = Snapceipt.ID.uuidv7(),
        userId: String,
        quoteId: String,
        itemDescription: String,
        quantity: Int = 1,
        unitPriceCents: Int,
        sortOrder: Int = 0,
        createdAt: Int = Epoch.nowMs(),
        updatedAt: Int = Epoch.nowMs(),
        deletedAt: Int? = nil,
        rev: Int = 0,
        lastEditedDeviceId: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.profileId = nil
        self.quoteId = quoteId
        self.itemDescription = itemDescription
        self.quantity = quantity
        self.unitPriceCents = unitPriceCents
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
        self.lastEditedDeviceId = lastEditedDeviceId
    }
}
