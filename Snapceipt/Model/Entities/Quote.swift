import Foundation
import SwiftData

/// A client quote (Business). Totals are server-recomputed on save. Mirrors D1 `quotes`.
@Model
final class Quote: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?

    var number: String?
    var clientId: String? = nil
    var clientName: String?
    var clientEmail: String?
    /// Snapshot of the picked client's freeform address at save (mirrors clientName/
    /// clientEmail; no FK). Mirrors D1 `quotes.client_address`.
    var clientAddress: String?
    /// Snapshot of the picked client's mobile phone at save (mirrors clientAddress).
    /// Mirrors D1 `quotes.client_mobile`; rendered in the To block of the hosted quote.
    var clientMobile: String?
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
    /// R2 key of the last-generated quote PDF (persisted; re-shareable from history). (spec §3)
    var pdfR2Key: String?
    /// The invoice this quote was converted into, if any (one-to-one). (spec §4.2)
    var invoiceId: String?
    /// GST rate snapshot in basis points, set from the profile at save. null ⇒ 10%
    /// (1000) for legacy quotes. Totals + the "GST (X%)" label read THIS value. (spec §3)
    var gstRateBp: Int?

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
        clientId: String? = nil,
        clientName: String? = nil,
        clientEmail: String? = nil,
        clientAddress: String? = nil,
        clientMobile: String? = nil,
        gstEnabled: Bool = true,
        gstInclusive: Bool = false,
        subtotalCents: Int = 0,
        gstCents: Int = 0,
        totalCents: Int = 0,
        currency: String = "AUD",
        status: String = "draft",
        validUntil: String? = nil,
        sentAt: Int? = nil,
        pdfR2Key: String? = nil,
        invoiceId: String? = nil,
        gstRateBp: Int? = nil,
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
        self.clientId = clientId
        self.clientName = clientName
        self.clientEmail = clientEmail
        self.clientAddress = clientAddress
        self.clientMobile = clientMobile
        self.gstEnabled = gstEnabled
        self.gstInclusive = gstInclusive
        self.subtotalCents = subtotalCents
        self.gstCents = gstCents
        self.totalCents = totalCents
        self.currency = currency
        self.status = status
        self.validUntil = validUntil
        self.sentAt = sentAt
        self.pdfR2Key = pdfR2Key
        self.invoiceId = invoiceId
        self.gstRateBp = gstRateBp
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
        self.lastEditedDeviceId = lastEditedDeviceId
    }
}
