import Foundation
import SwiftData

/// A per-category / per-profile spend cap. Mirrors D1 `budgets`. Spent is computed
/// from transactions, never stored.
@Model
final class Budget: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?

    var categoryId: String?
    var catKey: String?
    var label: String
    var period: String               // "monthly"
    var monthKey: String?            // "YYYY-MM"
    var capCents: Int
    var currency: String
    var alertThresholdPct: Int
    var alertSentAt: Int?

    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var rev: Int
    var lastEditedDeviceId: String?

    var entityType: EntityType { .budget }

    init(
        id: String = Snapceipt.ID.uuidv7(),
        userId: String,
        profileId: String?,
        categoryId: String? = nil,
        catKey: String? = nil,
        label: String,
        period: String = "monthly",
        monthKey: String? = nil,
        capCents: Int,
        currency: String = "AUD",
        alertThresholdPct: Int = 90,
        alertSentAt: Int? = nil,
        createdAt: Int = Clock.nowMs(),
        updatedAt: Int = Clock.nowMs(),
        deletedAt: Int? = nil,
        rev: Int = 0,
        lastEditedDeviceId: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.profileId = profileId
        self.categoryId = categoryId
        self.catKey = catKey
        self.label = label
        self.period = period
        self.monthKey = monthKey
        self.capCents = capCents
        self.currency = currency
        self.alertThresholdPct = alertThresholdPct
        self.alertSentAt = alertSentAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
        self.lastEditedDeviceId = lastEditedDeviceId
    }
}
