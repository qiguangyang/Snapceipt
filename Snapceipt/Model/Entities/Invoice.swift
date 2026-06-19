import Foundation
import SwiftData

/// A tax invoice (Business). Totals are server-recomputed on issue. Mirrors D1 `invoices`.
/// Derived A/R state (amountPaid / paymentState / isOverdue) is NOT stored — see
/// `AccountsReceivable`.
@Model
final class Invoice: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?

    var number: String?              // minted on issue (POST /invoices/:id/issue)
    var quoteId: String?             // origin link (the quote this was converted from)
    var clientName: String?
    var clientEmail: String?
    var gstEnabled: Bool
    var gstInclusive: Bool
    var subtotalCents: Int
    var gstCents: Int
    var totalCents: Int
    var currency: String
    var status: String               // "draft" | "issued" | "void"
    var issueDate: String?           // "YYYY-MM-DD" (set on issue)
    var dueDate: String?             // "YYYY-MM-DD" (editable; default today+14)
    var issuedAt: Int?               // epoch ms (set on issue)
    var pdfR2Key: String?            // persisted R2 key of the last-built PDF

    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var rev: Int
    var lastEditedDeviceId: String?

    var entityType: EntityType { .invoice }

    init(
        id: String = Snapceipt.ID.uuidv7(),
        userId: String,
        profileId: String?,
        number: String? = nil,
        quoteId: String? = nil,
        clientName: String? = nil,
        clientEmail: String? = nil,
        gstEnabled: Bool = true,
        gstInclusive: Bool = false,
        subtotalCents: Int = 0,
        gstCents: Int = 0,
        totalCents: Int = 0,
        currency: String = "AUD",
        status: String = "draft",
        issueDate: String? = nil,
        dueDate: String? = nil,
        issuedAt: Int? = nil,
        pdfR2Key: String? = nil,
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
        self.quoteId = quoteId
        self.clientName = clientName
        self.clientEmail = clientEmail
        self.gstEnabled = gstEnabled
        self.gstInclusive = gstInclusive
        self.subtotalCents = subtotalCents
        self.gstCents = gstCents
        self.totalCents = totalCents
        self.currency = currency
        self.status = status
        self.issueDate = issueDate
        self.dueDate = dueDate
        self.issuedAt = issuedAt
        self.pdfR2Key = pdfR2Key
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
        self.lastEditedDeviceId = lastEditedDeviceId
    }
}
