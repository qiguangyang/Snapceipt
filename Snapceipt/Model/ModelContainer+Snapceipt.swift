import Foundation
import SwiftData

/// The full Snapceipt SwiftData schema: the 20 syncable domain models, the
/// offline OutboxMutation queue, and the local-only PendingReceipt artifact.
enum SnapceiptSchema {
    static let models: [any PersistentModel.Type] = [
        Profile.self,
        Transaction.self,
        LineItem.self,
        Category.self,
        SmartRule.self,
        Budget.self,
        LoyaltyCard.self,
        MileageTrip.self,
        WFHLog.self,
        Quote.self,
        QuoteLineItem.self,
        TaxSettings.self,
        Vehicle.self,
        VehicleYear.self,
        Client.self,
        Invoice.self,
        InvoiceLineItem.self,
        Payment.self,
        CatalogItem.self,
        ClientFollowUp.self,
        OutboxMutation.self,
        PendingReceipt.self,
    ]

    static let schema = Schema(models)
}

extension ModelContainer {
    /// Builds the app's ModelContainer. Pass `inMemory: true` for tests/previews
    /// (ephemeral store) and `false` for the on-disk app store.
    static func makeSnapceiptContainer(inMemory: Bool = false) throws -> ModelContainer {
        let config = ModelConfiguration(
            schema: SnapceiptSchema.schema,
            isStoredInMemoryOnly: inMemory
        )
        return try ModelContainer(for: SnapceiptSchema.schema, configurations: [config])
    }
}

/// Builds the app's shared `ModelContainer` for non-throwing call sites (app
/// launch, previews). Wraps `ModelContainer.makeSnapceiptContainer(inMemory:)`
/// and falls back to an in-memory store if the on-disk store is corrupt/
/// incompatible (the real migration/reset flow is owned by a later task).
func makeSnapceiptContainer(inMemory: Bool = false) -> ModelContainer {
    do {
        return try ModelContainer.makeSnapceiptContainer(inMemory: inMemory)
    } catch {
        let fallback = ModelConfiguration(
            schema: SnapceiptSchema.schema,
            isStoredInMemoryOnly: true
        )
        // swiftlint:disable:next force_try
        return try! ModelContainer(for: SnapceiptSchema.schema, configurations: [fallback])
    }
}
