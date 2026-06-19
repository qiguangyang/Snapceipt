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
    /// GST rate in basis points (1000 = 10%, 1500 = 15%). Device-region default at
    /// business-profile creation; the default rate for NEW documents (snapshotted onto
    /// each quote/invoice). Mirrors D1 `profiles.gst_rate_bp`. (spec §3)
    var gstRateBp: Int
    /// Business contact + payment details rendered on the HTML quote (each shown only
    /// when set). All freeform/optional; `addressText` + `bankDetails` are multiline. (spec §5)
    var businessEmail: String?
    var phone: String?
    var website: String?
    var addressText: String?
    var bankDetails: String?
    /// R2 key of the uploaded logo. SERVER-OWNED — pull-only on iOS (decode, never
    /// encode), set by POST /profile/logo. (spec §7, mirrors pdfR2Key's N1 fix)
    var logoR2Key: String?
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
        gstRateBp: Int = 1000,
        businessEmail: String? = nil,
        phone: String? = nil,
        website: String? = nil,
        addressText: String? = nil,
        bankDetails: String? = nil,
        logoR2Key: String? = nil,
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
        self.gstRateBp = gstRateBp
        self.businessEmail = businessEmail
        self.phone = phone
        self.website = website
        self.addressText = addressText
        self.bankDetails = bankDetails
        self.logoR2Key = logoR2Key
        self.sortOrder = sortOrder
        self.isDefault = isDefault
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
        self.lastEditedDeviceId = lastEditedDeviceId
    }
}
