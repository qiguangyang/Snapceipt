import Foundation
import SwiftData

/// A loyalty card with a scannable barcode. Mirrors D1 `loyalty_cards`.
@Model
final class LoyaltyCard: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?

    var brand: String
    var subBrand: String?
    var number: String
    var barcodeFormat: String?       // "code128" | "ean13" | "qr" | "aztec" | "pdf417" | nil
    var pointsLabel: String?
    var color1: String               // hex
    var color2: String               // hex
    var sortOrder: Int

    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var rev: Int
    var lastEditedDeviceId: String?

    var entityType: EntityType { .loyaltyCard }

    init(
        id: String = Snapceipt.ID.uuidv7(),
        userId: String,
        profileId: String? = nil,
        brand: String,
        subBrand: String? = nil,
        number: String,
        barcodeFormat: String? = nil,
        pointsLabel: String? = nil,
        color1: String,
        color2: String,
        sortOrder: Int = 0,
        createdAt: Int = Epoch.nowMs(),
        updatedAt: Int = Epoch.nowMs(),
        deletedAt: Int? = nil,
        rev: Int = 0,
        lastEditedDeviceId: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.profileId = profileId
        self.brand = brand
        self.subBrand = subBrand
        self.number = number
        self.barcodeFormat = barcodeFormat
        self.pointsLabel = pointsLabel
        self.color1 = color1
        self.color2 = color2
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
        self.lastEditedDeviceId = lastEditedDeviceId
    }
}
