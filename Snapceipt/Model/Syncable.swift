import Foundation

/// The shared sync envelope. Every syncable `@Model` declares these eight stored
/// properties identically (SwiftData cannot synthesize stored protocol props), and
/// conforms to `Syncable` so generic push/pull code can read them uniformly.
/// Names mirror the backend `rowToEntity` camelCase envelope 1:1.
protocol Syncable {
    /// Client-generated UUIDv7 primary key.
    var id: String { get }
    /// Tenant boundary — the owning user's id.
    var userId: String { get }
    /// UI sub-scope; nil on types that aren't profile-scoped (profile, lineItem, quoteLineItem).
    var profileId: String? { get }
    /// Epoch-ms creation time.
    var createdAt: Int { get }
    /// Epoch-ms last-write time — the LWW key + pull cursor component.
    var updatedAt: Int { get }
    /// Soft-delete tombstone (epoch ms) or nil when live.
    var deletedAt: Int? { get }
    /// Server-stamped revision; bumped on each accepted write.
    var rev: Int { get }
    /// Device that produced the last edit (for conflict diagnostics).
    var lastEditedDeviceId: String? { get }

    /// The entity type used for sync routing (constant per concrete model).
    var entityType: EntityType { get }
}
