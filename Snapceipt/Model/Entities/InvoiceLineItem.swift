import Foundation
import SwiftData

/// A line on an invoice, owned by its parent Invoice. Mirrors D1 `invoice_line_items`.
/// `lineTotalCents` is computed locally (quantity * unitPriceCents) — never a synced field.
@Model
final class InvoiceLineItem: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?           // always nil (child of an invoice)

    var invoiceId: String
    var itemDescription: String      // maps to backend "description"
    var quantity: Int
    var unitPriceCents: Int
    var sortOrder: Int

    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var rev: Int
    var lastEditedDeviceId: String?

    var entityType: EntityType { .invoiceLineItem }

    var lineTotalCents: Int { quantity * unitPriceCents }

    init(
        id: String = Snapceipt.ID.uuidv7(),
        userId: String,
        invoiceId: String,
        itemDescription: String,
        quantity: Int = 1,
        unitPriceCents: Int,
        sortOrder: Int = 0,
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
        self.itemDescription = itemDescription
        self.quantity = quantity
        self.unitPriceCents = unitPriceCents
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
        self.lastEditedDeviceId = lastEditedDeviceId
    }
}
