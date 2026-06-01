import Foundation
import SwiftData

/// Local-only artifact for a saved scan. NOT a `Syncable` (no `EntityType`, never
/// enqueued) — it only drives the image-upload queue + the re-extract reconciler,
/// then is deleted once both finish. Registered in `SnapceiptSchema.models`.
@Model
final class PendingReceipt {
    @Attribute(.unique) var id: String
    /// The parent transaction this receipt belongs to.
    var transactionId: String
    /// OCR dump, kept so the reconciler can re-call `/extract` for a pending txn.
    var ocrText: String
    /// Absolute path of the reduced JPEG under Application Support (deleted on done).
    var imageLocalPath: String
    var width: Int
    var height: Int
    /// "pending" | "done" | "failed".
    var uploadState: String
    var uploadAttempts: Int
    var extractionAttempts: Int
    var createdAt: Int

    init(id: String = Snapceipt.ID.uuidv7(),
         transactionId: String,
         ocrText: String,
         imageLocalPath: String,
         width: Int,
         height: Int,
         uploadState: String = "pending",
         uploadAttempts: Int = 0,
         extractionAttempts: Int = 0,
         createdAt: Int = Epoch.nowMs()) {
        self.id = id
        self.transactionId = transactionId
        self.ocrText = ocrText
        self.imageLocalPath = imageLocalPath
        self.width = width
        self.height = height
        self.uploadState = uploadState
        self.uploadAttempts = uploadAttempts
        self.extractionAttempts = extractionAttempts
        self.createdAt = createdAt
    }
}
