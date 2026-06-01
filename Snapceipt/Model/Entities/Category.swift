import Foundation
import SwiftData

/// A spend category. Mirrors D1 `categories`. `key` is a `CategoryKey` raw value
/// or "custom"; `tint`/`soft` are hex strings.
@Model
final class Category: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?

    var key: String                  // CategoryKey raw value or "custom"
    var label: String
    var icon: String
    var tint: String                 // hex
    var soft: String                 // hex
    var defaultDeductiblePct: Int?
    var isIncome: Bool
    var sortOrder: Int

    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var rev: Int
    var lastEditedDeviceId: String?

    var entityType: EntityType { .category }

    init(
        id: String = Snapceipt.ID.uuidv7(),
        userId: String,
        profileId: String? = nil,
        key: String,
        label: String,
        icon: String,
        tint: String,
        soft: String,
        defaultDeductiblePct: Int? = nil,
        isIncome: Bool = false,
        sortOrder: Int = 0,
        createdAt: Int = Epoch.nowMs(),
        updatedAt: Int = Epoch.nowMs(),
        deletedAt: Int? = nil,
        rev: Int = 0,
        lastEditedDeviceId: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.profileId = profileId
        self.key = key
        self.label = label
        self.icon = icon
        self.tint = tint
        self.soft = soft
        self.defaultDeductiblePct = defaultDeductiblePct
        self.isIncome = isIncome
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
        self.lastEditedDeviceId = lastEditedDeviceId
    }
}
