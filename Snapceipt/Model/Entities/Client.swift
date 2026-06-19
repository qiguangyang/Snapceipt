import Foundation
import SwiftData

/// A saved client in the per-profile address book (Business). Mirrors D1 `clients`.
/// Picking a Client copies its name/email/address onto the quote (no FK), keeping a
/// sent quote stable. Carries name + email + freeform multiline address.
@Model
final class Client: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?

    var name: String
    var email: String?
    /// Freeform multiline address (optional). Mirrors D1 `clients.address`.
    var address: String?

    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var rev: Int
    var lastEditedDeviceId: String?

    var entityType: EntityType { .client }

    init(
        id: String = Snapceipt.ID.uuidv7(),
        userId: String,
        profileId: String?,
        name: String,
        email: String? = nil,
        address: String? = nil,
        createdAt: Int = Epoch.nowMs(),
        updatedAt: Int = Epoch.nowMs(),
        deletedAt: Int? = nil,
        rev: Int = 0,
        lastEditedDeviceId: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.profileId = profileId
        self.name = name
        self.email = email
        self.address = address
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
        self.lastEditedDeviceId = lastEditedDeviceId
    }
}
