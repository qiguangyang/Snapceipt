import Foundation
import SwiftData

/// One queued local mutation awaiting push. The SyncEngine drains these; the
/// `mutationId` is the server idempotency key. `payloadJSON` holds the full
/// camelCase entity snapshot for an upsert, or just the id for a delete.
@Model
final class OutboxMutation {
    /// Stable idempotency key (UUIDv7) sent as PushMutation.mutationId.
    @Attribute(.unique) var mutationId: String
    /// EntityType raw value (e.g. "transaction").
    var entityType: String
    /// The target entity's id.
    var entityId: String
    /// "upsert" | "delete".
    var op: String
    /// JSON snapshot of the entity (upsert) or `{ "id": ... }` (delete).
    var payloadJSON: String
    /// The local rev the edit was based on (for server LWW tie-breaking); nil if new.
    var baseRev: Int?
    /// Epoch-ms enqueue time (drain order).
    var createdAt: Int
    /// Retry counter for backoff.
    var attemptCount: Int
    /// "pending" | "inflight" | "acked" | "failed".
    var status: String

    init(
        mutationId: String = Snapceipt.ID.uuidv7(),
        entityType: String,
        entityId: String,
        op: String,
        payloadJSON: String,
        baseRev: Int? = nil,
        createdAt: Int = Epoch.nowMs(),
        attemptCount: Int = 0,
        status: String = "pending"
    ) {
        self.mutationId = mutationId
        self.entityType = entityType
        self.entityId = entityId
        self.op = op
        self.payloadJSON = payloadJSON
        self.baseRev = baseRev
        self.createdAt = createdAt
        self.attemptCount = attemptCount
        self.status = status
    }
}
