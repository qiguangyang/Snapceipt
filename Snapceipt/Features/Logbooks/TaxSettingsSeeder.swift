import Foundation
import SwiftData

/// Ensures every profile has exactly one live `TaxSettings` row with ATO defaults.
/// Hooked on profile creation and lazily on logbook-screen load (legacy profiles). (§7)
@MainActor
enum TaxSettingsSeeder {
    /// Insert a defaulted `TaxSettings` for `profileId` if none exists (live).
    /// Idempotent; enqueues an upsert only when it inserts.
    static func ensure(profileId: String, userId: String,
                       context: ModelContext, sync: any SyncEnqueuing) {
        var d = FetchDescriptor<TaxSettings>(
            predicate: #Predicate { $0.profileId == profileId && $0.deletedAt == nil })
        d.fetchLimit = 1
        if let existing = try? context.fetch(d), existing.isEmpty == false { return }

        let settings = TaxSettings(userId: userId, profileId: profileId)  // ATO defaults
        context.insert(settings)
        try? context.save()
        sync.enqueue(op: "upsert", entityType: .taxSettings, entity: settings)
    }
}
