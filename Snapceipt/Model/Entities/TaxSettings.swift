import Foundation
import SwiftData

/// Per-profile AU tax configuration. Mirrors D1 `tax_settings`.
@Model
final class TaxSettings: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?

    var gstRateBps: Int              // 1000 = 10%
    var financialYearStartMonth: Int // 7 = July (AU FY)
    var mealsDeductiblePct: Int
    var wfhRateCentsPerHour: Int
    var mileageRateCentsPerKm: Int

    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var rev: Int
    var lastEditedDeviceId: String?

    var entityType: EntityType { .taxSettings }

    init(
        id: String = Snapceipt.ID.uuidv7(),
        userId: String,
        profileId: String?,
        gstRateBps: Int = 1000,
        financialYearStartMonth: Int = 7,
        mealsDeductiblePct: Int = 50,
        wfhRateCentsPerHour: Int = 70,
        mileageRateCentsPerKm: Int = 88,
        createdAt: Int = Epoch.nowMs(),
        updatedAt: Int = Epoch.nowMs(),
        deletedAt: Int? = nil,
        rev: Int = 0,
        lastEditedDeviceId: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.profileId = profileId
        self.gstRateBps = gstRateBps
        self.financialYearStartMonth = financialYearStartMonth
        self.mealsDeductiblePct = mealsDeductiblePct
        self.wfhRateCentsPerHour = wfhRateCentsPerHour
        self.mileageRateCentsPerKm = mileageRateCentsPerKm
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
        self.lastEditedDeviceId = lastEditedDeviceId
    }
}
