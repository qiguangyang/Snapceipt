import Foundation
import SwiftData

/// An in-app follow-up record; device notification state is local and is not synced.
/// Callers validate required domain fields before local save.
@Model
final class ClientFollowUp: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?

    var clientId: String
    var title: String
    var dueAt: Int
    var timezone: String
    var completedAt: Int?

    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var rev: Int
    var lastEditedDeviceId: String?

    var entityType: EntityType { .clientFollowUp }

    init(
        id: String = Snapceipt.ID.uuidv7(),
        userId: String,
        profileId: String,
        clientId: String = "",
        title: String = "",
        dueAt: Int = 0,
        timezone: String = "UTC",
        completedAt: Int? = nil,
        createdAt: Int = Epoch.nowMs(),
        updatedAt: Int = Epoch.nowMs(),
        deletedAt: Int? = nil,
        rev: Int = 0,
        lastEditedDeviceId: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.profileId = profileId
        self.clientId = clientId
        self.title = title
        self.dueAt = dueAt
        self.timezone = timezone
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
        self.lastEditedDeviceId = lastEditedDeviceId
    }
}
