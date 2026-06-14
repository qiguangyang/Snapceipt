import Foundation
import SwiftData

/// A client quote (Business). Totals are server-recomputed on save. Mirrors D1 `quotes`.
@Model
final class Quote: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?

    var number: String?
    var clientName: String?
    var clientEmail: String?
    var gstEnabled: Bool
    /// When true (and `gstEnabled`), entered line prices already include GST: the
    /// grand total is the entered sum and GST is the embedded 1/11 portion. Default
    /// false = GST added on top (exclusive). Mirrors D1 `quotes.gst_inclusive`.
    var gstInclusive: Bool
    var subtotalCents: Int
    var gstCents: Int
    var totalCents: Int
    var currency: String
    var status: String               // "draft" | "sent" | "accepted" | "declined" | "expired" | "invoiced"
    var validUntil: String?          // "YYYY-MM-DD"
    var sentAt: Int?

    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var rev: Int
    var lastEditedDeviceId: String?

    var entityType: EntityType { .quote }

    init(
        id: String = Snapceipt.ID.uuidv7(),
        userId: String,
        profileId: String?,
        number: String? = nil,
        clientName: String? = nil,
        clientEmail: String? = nil,
        gstEnabled: Bool = true,
        gstInclusive: Bool = false,
        subtotalCents: Int = 0,
        gstCents: Int = 0,
        totalCents: Int = 0,
        currency: String = "AUD",
        status: String = "draft",
        validUntil: String? = nil,
        sentAt: Int? = nil,
        createdAt: Int = Epoch.nowMs(),
        updatedAt: Int = Epoch.nowMs(),
        deletedAt: Int? = nil,
        rev: Int = 0,
        lastEditedDeviceId: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.profileId = profileId
        self.number = number
        self.clientName = clientName
        self.clientEmail = clientEmail
        self.gstEnabled = gstEnabled
        self.gstInclusive = gstInclusive
        self.subtotalCents = subtotalCents
        self.gstCents = gstCents
        self.totalCents = totalCents
        self.currency = currency
        self.status = status
        self.validUntil = validUntil
        self.sentAt = sentAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
        self.lastEditedDeviceId = lastEditedDeviceId
    }
}
