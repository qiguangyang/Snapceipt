import Foundation
import SwiftData

/// A saved service description and current price, scoped to a user and profile.
/// Callers validate required domain fields before local save.
@Model
final class CatalogItem: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?

    var itemDescription: String
    var unitLabel: String?
    var unitPriceCents: Int
    var currency: String

    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var rev: Int
    var lastEditedDeviceId: String?

    var entityType: EntityType { .catalogItem }

    init(
        id: String = Snapceipt.ID.uuidv7(),
        userId: String,
        profileId: String,
        itemDescription: String = "",
        unitLabel: String? = nil,
        unitPriceCents: Int = 0,
        currency: String = "AUD",
        createdAt: Int = Epoch.nowMs(),
        updatedAt: Int = Epoch.nowMs(),
        deletedAt: Int? = nil,
        rev: Int = 0,
        lastEditedDeviceId: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.profileId = profileId
        self.itemDescription = itemDescription
        self.unitLabel = unitLabel
        self.unitPriceCents = unitPriceCents
        self.currency = currency
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
        self.lastEditedDeviceId = lastEditedDeviceId
    }
}
