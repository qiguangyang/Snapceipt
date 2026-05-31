import Foundation
import SwiftData

/// One vehicle's running costs + claim for a single financial year. Mirrors D1
/// `vehicle_years` (§4.4). `fyStartYear` 2025 => FY2025-26. `claimCents` is cached
/// = `businessUsePct%` × sum(costs), with `businessUsePct` snapshotted at compute.
@Model
final class VehicleYear: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?

    var vehicleId: String
    var fyStartYear: Int            // 2025 => FY2025-26
    var odometerOpenM: Int?
    var odometerCloseM: Int?
    var fuelCents: Int
    var regoCents: Int
    var insuranceCents: Int
    var servicingCents: Int
    var otherCents: Int
    var depreciationCents: Int
    var businessUsePct: Int?        // snapshot at compute time
    var claimCents: Int?            // cached = pct% * sum(costs)

    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var rev: Int
    var lastEditedDeviceId: String?

    var entityType: EntityType { .vehicleYear }

    init(
        id: String = Snapceipt.ID.uuidv7(),
        userId: String,
        profileId: String?,
        vehicleId: String,
        fyStartYear: Int,
        odometerOpenM: Int? = nil,
        odometerCloseM: Int? = nil,
        fuelCents: Int = 0,
        regoCents: Int = 0,
        insuranceCents: Int = 0,
        servicingCents: Int = 0,
        otherCents: Int = 0,
        depreciationCents: Int = 0,
        businessUsePct: Int? = nil,
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
        self.vehicleId = vehicleId
        self.fyStartYear = fyStartYear
        self.odometerOpenM = odometerOpenM
        self.odometerCloseM = odometerCloseM
        self.fuelCents = fuelCents
        self.regoCents = regoCents
        self.insuranceCents = insuranceCents
        self.servicingCents = servicingCents
        self.otherCents = otherCents
        self.depreciationCents = depreciationCents
        self.businessUsePct = businessUsePct
        self.claimCents = claimCents
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
        self.lastEditedDeviceId = lastEditedDeviceId
    }
}
