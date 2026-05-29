import Foundation
import SwiftData

/// Central place that knows the full SwiftData schema for the app.
/// Later tasks append their `@Model` types to `snapceiptSchema`.
enum SnapceiptSchema {
    /// Every persisted `@Model` type. Empty in the foundation scaffold;
    /// Task 3+ register `Profile`, `Transaction`, `OutboxMutation`, etc. here.
    static var models: [any PersistentModel.Type] { [] }

    static var schema: Schema { Schema(models) }
}

/// Builds the app's shared `ModelContainer`.
/// - Parameter inMemory: when `true`, nothing is written to disk (used by tests/previews).
func makeSnapceiptContainer(inMemory: Bool = false) -> ModelContainer {
    let configuration = ModelConfiguration(
        schema: SnapceiptSchema.schema,
        isStoredInMemoryOnly: inMemory
    )
    do {
        return try ModelContainer(
            for: SnapceiptSchema.schema,
            configurations: [configuration]
        )
    } catch {
        // A failure here means the on-disk store is incompatible/corrupt.
        // Fall back to an in-memory store so the app still launches; the
        // real recovery flow (migration/reset) is owned by a later task.
        let fallback = ModelConfiguration(
            schema: SnapceiptSchema.schema,
            isStoredInMemoryOnly: true
        )
        // swiftlint:disable:next force_try
        return try! ModelContainer(for: SnapceiptSchema.schema, configurations: [fallback])
    }
}
