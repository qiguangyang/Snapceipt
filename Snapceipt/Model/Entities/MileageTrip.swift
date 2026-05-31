import Foundation
import SwiftData

/// A logged vehicle trip (manual; GPS auto-track is placeholder in v1).
/// Mirrors D1 `mileage_trips`. `distanceM` is metres.
@Model
final class MileageTrip: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?

    var tripDate: String             // "YYYY-MM-DD"
    var fromLabel: String?
    var toLabel: String?
    var purpose: String?
    var distanceM: Int               // metres
    var isBusiness: Bool
    var rateCentsPerKm: Int?
    var claimCents: Int?
    var autoTracked: Bool
    var vehicleId: String?           // FK -> vehicles(id); the trip's car
    var odometerStartM: Int?         // metres
    var odometerEndM: Int?           // metres; must be > start

    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var rev: Int
    var lastEditedDeviceId: String?

    var entityType: EntityType { .mileageTrip }

    init(
        id: String = Snapceipt.ID.uuidv7(),
        userId: String,
        profileId: String?,
        tripDate: String,
        fromLabel: String? = nil,
        toLabel: String? = nil,
        purpose: String? = nil,
        distanceM: Int,
        isBusiness: Bool = true,
        rateCentsPerKm: Int? = nil,
        claimCents: Int? = nil,
        autoTracked: Bool = false,
        vehicleId: String? = nil,
        odometerStartM: Int? = nil,
        odometerEndM: Int? = nil,
        createdAt: Int = Epoch.nowMs(),
        updatedAt: Int = Epoch.nowMs(),
        deletedAt: Int? = nil,
        rev: Int = 0,
        lastEditedDeviceId: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.profileId = profileId
        self.tripDate = tripDate
        self.fromLabel = fromLabel
        self.toLabel = toLabel
        self.purpose = purpose
        self.distanceM = distanceM
        self.isBusiness = isBusiness
        self.rateCentsPerKm = rateCentsPerKm
        self.claimCents = claimCents
        self.autoTracked = autoTracked
        self.vehicleId = vehicleId
        self.odometerStartM = odometerStartM
        self.odometerEndM = odometerEndM
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
        self.lastEditedDeviceId = lastEditedDeviceId
    }
}
