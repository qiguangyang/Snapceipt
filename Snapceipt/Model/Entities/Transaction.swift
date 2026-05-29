import Foundation
import SwiftData

/// A ledger entry (expense negative, income positive). Mirrors D1 `transactions`.
/// `catKey` stores a `CategoryKey` raw value (or "custom"); `amountCents` is signed cents.
@Model
final class Transaction: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?

    var merchant: String
    var categoryId: String?
    var catKey: String               // CategoryKey raw value or "custom"
    var amountCents: Int             // signed: expense < 0, income > 0
    var currency: String
    var txnDate: String              // "YYYY-MM-DD"
    var mode: String                 // "business" | "personal"
    var taxLabel: String?
    var deductiblePct: Int?
    var paymentMethod: String?
    var isAi: Bool
    var note: String?
    var gstCents: Int?
    var logbookLink: String?         // "vehicle" | "wfh" | nil
    var mileageTripId: String?
    var source: String               // "manual" | "scan" | "email_in" | "import"
    var extractionStatus: String?    // "pending" | "done" | "failed" | nil

    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var rev: Int
    var lastEditedDeviceId: String?

    var entityType: EntityType { .transaction }

    init(
        id: String = Snapceipt.ID.uuidv7(),
        userId: String,
        profileId: String?,
        merchant: String = "",
        categoryId: String? = nil,
        catKey: String,
        amountCents: Int,
        currency: String = "AUD",
        txnDate: String,
        mode: String = "personal",
        taxLabel: String? = nil,
        deductiblePct: Int? = nil,
        paymentMethod: String? = nil,
        isAi: Bool = false,
        note: String? = nil,
        gstCents: Int? = nil,
        logbookLink: String? = nil,
        mileageTripId: String? = nil,
        source: String = "manual",
        extractionStatus: String? = nil,
        createdAt: Int = Clock.nowMs(),
        updatedAt: Int = Clock.nowMs(),
        deletedAt: Int? = nil,
        rev: Int = 0,
        lastEditedDeviceId: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.profileId = profileId
        self.merchant = merchant
        self.categoryId = categoryId
        self.catKey = catKey
        self.amountCents = amountCents
        self.currency = currency
        self.txnDate = txnDate
        self.mode = mode
        self.taxLabel = taxLabel
        self.deductiblePct = deductiblePct
        self.paymentMethod = paymentMethod
        self.isAi = isAi
        self.note = note
        self.gstCents = gstCents
        self.logbookLink = logbookLink
        self.mileageTripId = mileageTripId
        self.source = source
        self.extractionStatus = extractionStatus
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
        self.lastEditedDeviceId = lastEditedDeviceId
    }
}
