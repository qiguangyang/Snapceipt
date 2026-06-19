import Foundation
import SwiftData

/// A payment recorded against an invoice. Mirrors D1 `payments`. Multiple rows per
/// invoice; A/R state is DERIVED from the non-deleted set (see `AccountsReceivable`).
@Model
final class Payment: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?           // always nil (child of an invoice)

    var invoiceId: String
    var amountCents: Int
    var paidOn: String               // "YYYY-MM-DD"
    var method: String?
    var note: String?

    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var rev: Int
    var lastEditedDeviceId: String?

    var entityType: EntityType { .payment }

    init(
        id: String = Snapceipt.ID.uuidv7(),
        userId: String,
        invoiceId: String,
        amountCents: Int,
        paidOn: String,
        method: String? = nil,
        note: String? = nil,
        createdAt: Int = Epoch.nowMs(),
        updatedAt: Int = Epoch.nowMs(),
        deletedAt: Int? = nil,
        rev: Int = 0,
        lastEditedDeviceId: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.profileId = nil
        self.invoiceId = invoiceId
        self.amountCents = amountCents
        self.paidOn = paidOn
        self.method = method
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
        self.lastEditedDeviceId = lastEditedDeviceId
    }
}
