import Foundation
import SwiftData

/// A line on a receipt, owned by its parent Transaction. Mirrors D1 `line_items`.
@Model
final class LineItem: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?           // always nil (child of a transaction)

    var transactionId: String
    var name: String
    var priceCents: Int
    var quantity: Int
    var sortOrder: Int

    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var rev: Int
    var lastEditedDeviceId: String?

    var entityType: EntityType { .lineItem }

    init(
        id: String = Snapceipt.ID.uuidv7(),
        userId: String,
        transactionId: String,
        name: String,
        priceCents: Int,
        quantity: Int = 1,
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
        self.transactionId = transactionId
        self.name = name
        self.priceCents = priceCents
        self.quantity = quantity
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
        self.lastEditedDeviceId = lastEditedDeviceId
    }
}
