import Foundation
import SwiftData

/// A vehicle tracked under the ATO logbook method. Mirrors D1 `vehicles` (§4.3).
/// `businessUsePct` is cached from in-window trips; the logbook window is the
/// formal 12-week period (valid 5 years).
@Model
final class Vehicle: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?

    var make: String?
    var model: String?
    var engineCc: Int?
    var registration: String?
    var logbookStartDate: String?    // "YYYY-MM-DD", nil until logbook started
    var logbookEndDate: String?      // "YYYY-MM-DD", = start + ~12 weeks (editable)
    var businessUsePct: Int?         // 0..100, cached from in-window trips; nil until computed

    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var rev: Int
    var lastEditedDeviceId: String?

    var entityType: EntityType { .vehicle }

    init(
        id: String = Snapceipt.ID.uuidv7(),
        userId: String,
        profileId: String?,
        make: String? = nil,
        model: String? = nil,
        engineCc: Int? = nil,
        registration: String? = nil,
        logbookStartDate: String? = nil,
        logbookEndDate: String? = nil,
        businessUsePct: Int? = nil,
        createdAt: Int = Epoch.nowMs(),
        updatedAt: Int = Epoch.nowMs(),
        deletedAt: Int? = nil,
        rev: Int = 0,
        lastEditedDeviceId: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.profileId = profileId
        self.make = make
        self.model = model
        self.engineCc = engineCc
        self.registration = registration
        self.logbookStartDate = logbookStartDate
        self.logbookEndDate = logbookEndDate
        self.businessUsePct = businessUsePct
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
        self.lastEditedDeviceId = lastEditedDeviceId
    }
}
