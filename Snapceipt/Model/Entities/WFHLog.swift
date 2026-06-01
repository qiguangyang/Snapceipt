import Foundation
import SwiftData

/// A work-from-home day entry (fixed 70c/hr method). Mirrors D1 `wfh_logs`.
@Model
final class WFHLog: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?

    var logDate: String              // "YYYY-MM-DD"
    var minutes: Int
    var note: String?
    var rateCentsPerHour: Int?
    var claimCents: Int?

    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var rev: Int
    var lastEditedDeviceId: String?

    var entityType: EntityType { .wfhLog }

    init(
        id: String = Snapceipt.ID.uuidv7(),
        userId: String,
        profileId: String?,
        logDate: String,
        minutes: Int,
        note: String? = nil,
        rateCentsPerHour: Int? = nil,
        claimCents: Int? = nil,
        createdAt: Int = Epoch.nowMs(),
        updatedAt: Int = Epoch.nowMs(),
        deletedAt: Int? = nil,
        rev: Int = 0,
        lastEditedDeviceId: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.profileId = profileId
        self.logDate = logDate
        self.minutes = minutes
        self.note = note
        self.rateCentsPerHour = rateCentsPerHour
        self.claimCents = claimCents
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
        self.lastEditedDeviceId = lastEditedDeviceId
    }
}
