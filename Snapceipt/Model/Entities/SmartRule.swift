import Foundation
import SwiftData

/// An auto-categorization rule. Mirrors D1 `smart_rules`. Matches a transaction's
/// merchant and applies a category / deductible % / mode. Profile-scoped.
@Model
final class SmartRule: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?
    var matchType: String        // "merchant_contains" | "merchant_equals" | "merchant_regex"
    var matcher: String
    var categoryId: String?
    var setDeductiblePct: Int?
    var setMode: String?         // "business" | "personal" | nil
    var priority: Int
    var enabled: Bool
    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var rev: Int
    var lastEditedDeviceId: String?
    var entityType: EntityType { .smartRule }

    init(id: String = Snapceipt.ID.uuidv7(), userId: String, profileId: String? = nil,
         matchType: String = "merchant_contains", matcher: String,
         categoryId: String? = nil, setDeductiblePct: Int? = nil, setMode: String? = nil,
         priority: Int = 0, enabled: Bool = true,
         createdAt: Int = Epoch.nowMs(), updatedAt: Int = Epoch.nowMs(),
         deletedAt: Int? = nil, rev: Int = 0, lastEditedDeviceId: String? = nil) {
        self.id = id; self.userId = userId; self.profileId = profileId
        self.matchType = matchType; self.matcher = matcher; self.categoryId = categoryId
        self.setDeductiblePct = setDeductiblePct; self.setMode = setMode
        self.priority = priority; self.enabled = enabled
        self.createdAt = createdAt; self.updatedAt = updatedAt
        self.deletedAt = deletedAt; self.rev = rev; self.lastEditedDeviceId = lastEditedDeviceId
    }
}
