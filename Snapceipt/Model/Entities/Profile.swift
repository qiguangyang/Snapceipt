import Foundation
import SwiftData

/// A switchable persona (Personal / Business). Drives the active accent palette.
/// Mirrors D1 `profiles`. `accent1/2/3` are the base/soft/deep hex strings.
@Model
final class Profile: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?           // always nil (a profile is not profile-scoped)

    var name: String
    var type: String                 // "personal" | "business"
    var initials: String?
    var accent1: String              // base hex, e.g. "#0E7C72"
    var accent2: String              // soft hex
    var accent3: String              // deep hex
    var abn: String?
    var gstRegistered: Bool
    var sortOrder: Int
    var isDefault: Bool

    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var rev: Int
    var lastEditedDeviceId: String?

    var entityType: EntityType { .profile }

    init(
        id: String = Snapceipt.ID.uuidv7(),
        userId: String,
        name: String,
        type: String,
        initials: String? = nil,
        accent1: String,
        accent2: String,
        accent3: String,
        abn: String? = nil,
        gstRegistered: Bool = false,
        sortOrder: Int = 0,
        isDefault: Bool = false,
        createdAt: Int = Epoch.nowMs(),
        updatedAt: Int = Epoch.nowMs(),
        deletedAt: Int? = nil,
        rev: Int = 0,
        lastEditedDeviceId: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.profileId = nil
        self.name = name
        self.type = type
        self.initials = initials
        self.accent1 = accent1
        self.accent2 = accent2
        self.accent3 = accent3
        self.abn = abn
        self.gstRegistered = gstRegistered
        self.sortOrder = sortOrder
        self.isDefault = isDefault
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
        self.lastEditedDeviceId = lastEditedDeviceId
    }
}
