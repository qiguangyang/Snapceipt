import Foundation
import SwiftData

/// Ensures the built-in `Category` rows exist for a profile (idempotent), derived
/// from the `CategoryKey` taxonomy in `Snapceipt/Model/Categories.swift`. Mirrors
/// `TaxSettingsSeeder`.
///
/// Note on the taxonomy: `CategoryKey` has exactly 9 cases and **no `custom` case**
/// ("custom" is only a raw `String` the extractor / sync layer may store on a
/// `Transaction.catKey` / `Category.key`, never an enum case). So every case maps
/// to a managed row here. Display metadata (`label`/`icon`) is read from the
/// authoritative `CATS` table; `tint`/`soft` are stored as `#RRGGBB` hex strings
/// (the `Category` model stores them as strings, while `CATS` exposes `Color`), and
/// the per-key default-deductible % + `isIncome` flag are supplied here.
@MainActor
enum CategorySeeder {
    /// (tint, soft) as `#RRGGBB` hex + default deductible % + isIncome, per key.
    /// Hex values mirror `CATS` in `Snapceipt/Model/Categories.swift` exactly.
    private struct SeedMeta {
        let tintHex: String
        let softHex: String
        let defaultDeductiblePct: Int
        let isIncome: Bool
    }

    private static let seedMeta: [CategoryKey: SeedMeta] = [
        .meals:     SeedMeta(tintHex: "#E8602C", softHex: "#FBEADF", defaultDeductiblePct: 50,  isIncome: false),
        .groceries: SeedMeta(tintHex: "#C99A22", softHex: "#F6EECE", defaultDeductiblePct: 0,   isIncome: false),
        .fuel:      SeedMeta(tintHex: "#2F6FB0", softHex: "#E2ECF6", defaultDeductiblePct: 100, isIncome: false),
        .software:  SeedMeta(tintHex: "#7B5BD6", softHex: "#EBE5F8", defaultDeductiblePct: 100, isIncome: false),
        .office:    SeedMeta(tintHex: "#0E7C72", softHex: "#DCF0ED", defaultDeductiblePct: 100, isIncome: false),
        .home:      SeedMeta(tintHex: "#B0568F", softHex: "#F4E4EF", defaultDeductiblePct: 0,   isIncome: false),
        .health:    SeedMeta(tintHex: "#D6452B", softHex: "#F8E2DD", defaultDeductiblePct: 0,   isIncome: false),
        .travel:    SeedMeta(tintHex: "#1F9D6B", softHex: "#DEF3E9", defaultDeductiblePct: 100, isIncome: false),
        .income:    SeedMeta(tintHex: "#1F9D6B", softHex: "#DEF3E9", defaultDeductiblePct: 0,   isIncome: true),
    ]

    /// The only GST-free-by-default category (review §4.2): groceries. Everything
    /// else (meals/fuel/software/office/home/health/travel/income) is taxable.
    static let gstFreeDefaultByKey: [CategoryKey: Bool] = [.groceries: true]

    /// Insert the built-in `Category` rows for `profileId` that don't yet exist
    /// (live). Idempotent; enqueues an upsert only for the rows it inserts.
    static func ensure(profileId: String, userId: String,
                       context: ModelContext, sync: any SyncEnqueuing) {
        let pid = profileId
        let existing = (try? context.fetch(FetchDescriptor<Category>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil }))) ?? []
        let haveKeys = Set(existing.map { $0.key })

        var sort = existing.count
        var inserted = false
        for key in CategoryKey.allCases {
            if haveKeys.contains(key.rawValue) { continue }
            let meta = CATS[key]
            let seed = seedMeta[key]
            let cat = Category(
                userId: userId,
                profileId: pid,
                key: key.rawValue,
                label: meta?.label ?? key.rawValue.capitalized,
                icon: meta?.iconName ?? "tag",
                tint: seed?.tintHex ?? "#000000",
                soft: seed?.softHex ?? "#FFFFFF",
                defaultDeductiblePct: seed?.defaultDeductiblePct,
                isIncome: seed?.isIncome ?? (key == .income),
                sortOrder: sort,
                gstFreeDefault: gstFreeDefaultByKey[key] ?? false)
            sort += 1
            context.insert(cat)
            sync.enqueue(op: "upsert", entityType: .category, entity: cat)
            inserted = true
        }
        if inserted { try? context.save() }
    }

    /// One-time per-profile backfill for installs that seeded categories BEFORE
    /// gstFreeDefault existed (insert-only `ensure()` never revisits existing rows).
    /// Sets gstFreeDefault on the known category rows to match the seed table
    /// (only groceries → true), enqueues their upserts, and marks done. Idempotent.
    static func backfillGstDefaults(profileId: String, context: ModelContext,
                                    sync: any SyncEnqueuing, defaults: UserDefaults = .standard) {
        let doneKey = "sc.bas.gstDefaultsBackfilled.\(profileId)"
        if defaults.bool(forKey: doneKey) { return }
        let pid = profileId
        let rows = (try? context.fetch(FetchDescriptor<Category>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil }))) ?? []
        var changed = false
        for row in rows {
            let want = (CategoryKey(rawValue: row.key)).flatMap { gstFreeDefaultByKey[$0] } ?? false
            if row.gstFreeDefault != want {
                row.gstFreeDefault = want
                row.updatedAt = Epoch.nowMs()
                sync.enqueue(op: "upsert", entityType: .category, entity: row)
                changed = true
            }
        }
        if changed { try? context.save() }
        defaults.set(true, forKey: doneKey)
    }
}
