import Foundation
import SwiftData
import Observation

/// Drives the add-card form. Brand pick (catalog + Custom) prefills brand/subBrand/
/// colors; scan prefills number + format. `save(sortOrder:)` creates the card scoped
/// to the active profile and enqueues an upsert. `@MainActor`; deps injected for tests.
@Observable
@MainActor
final class AddLoyaltyViewModel {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let sync: any SyncEnqueuing
    @ObservationIgnored private let userId: String
    @ObservationIgnored let profileId: String

    /// Catalog brands + the Custom path, in pick order.
    let brands: [LoyaltyBrand] = LoyaltyBrand.catalog + [LoyaltyBrand.custom]

    var selectedBrand: LoyaltyBrand?
    var customName: String = ""
    var number: String = ""
    /// Barcode symbology to render/store. Defaults to Code 128 (renders any digit
    /// string + what most AU loyalty cards use) so a manually-entered card ALWAYS
    /// shows a barcode; the scanner overrides it with the detected symbology, and the
    /// add form exposes a picker to change it.
    var format: LoyaltyCard.BarcodeFormat = .code128
    var search: String = ""

    init(context: ModelContext, sync: any SyncEnqueuing, userId: String, profileId: String) {
        self.context = context
        self.sync = sync
        self.userId = userId
        self.profileId = profileId
    }

    /// Catalog filtered by the search text (Custom always shown).
    var filteredBrands: [LoyaltyBrand] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return brands }
        return brands.filter { $0.key == "custom" || $0.name.lowercased().contains(q) }
    }

    /// Savable once a brand is chosen and a non-empty member number is entered
    /// (Custom also requires a non-empty brand name).
    var canSave: Bool {
        guard let b = selectedBrand else { return false }
        guard !number.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if b.key == "custom" { return !customName.trimmingCharacters(in: .whitespaces).isEmpty }
        return true
    }

    /// Create the card (profileId = active) + enqueue an upsert. Returns the new row,
    /// or nil if not savable.
    @discardableResult
    func save(sortOrder: Int) -> LoyaltyCard? {
        guard canSave, let b = selectedBrand else { return nil }
        let isCustom = b.key == "custom"
        let card = LoyaltyCard(
            userId: userId,
            profileId: profileId,
            brand: isCustom ? customName.trimmingCharacters(in: .whitespaces) : b.name,
            subBrand: isCustom ? nil : b.subBrand,
            number: number.trimmingCharacters(in: .whitespaces),
            barcodeFormat: format.rawValue,
            color1: b.color1,
            color2: b.color2,
            sortOrder: sortOrder)
        context.insert(card)
        try? context.save()
        sync.enqueue(op: "upsert", entityType: .loyaltyCard, entity: card)
        return card
    }
}
