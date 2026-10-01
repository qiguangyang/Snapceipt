import Foundation
import SwiftData
import SwiftUI

// MARK: - Sync seam

/// Seam over `SyncEngine` so view-models can enqueue a sync mutation — and force
/// an immediate outbox drain — while staying unit-testable (tests inject a
/// `MockSyncEngine` spy). `enqueue` mirrors `SyncEngine.enqueue` VERBATIM.
// @MainActor: enqueue/flush manipulate SyncEngine's main-actor-isolated outbox, and
// every caller (the @MainActor view-models, stores, and reconcilers) is already on the
// main actor — so isolate the protocol to match. This silences the Swift 6
// "conformance crosses into main actor-isolated code" error on `SyncEngine: SyncEnqueuing`.
@MainActor
protocol SyncEnqueuing: AnyObject {
    func enqueue(op: String, entityType: EntityType, entity: any Syncable)

    /// Queue using an isolated mutation context without saving unrelated editor changes.
    func enqueue(op: String, entityType: EntityType, entity: any Syncable, context: ModelContext)

    /// Drain the local outbox to the backend NOW, awaiting any in-flight sync
    /// first. Action endpoints that require a just-edited entity to already exist
    /// server-side (e.g. quote send) call this after `enqueue` so the upsert has
    /// reached D1 before the action fires. Default no-op for non-engine conformers
    /// (previews, test spies that don't model the network).
    func flush() async
}

extension SyncEnqueuing {
    func enqueue(op: String, entityType: EntityType, entity: any Syncable, context: ModelContext) {
        enqueue(op: op, entityType: entityType, entity: entity)
    }
    func flush() async {}
}

extension SyncEngine: SyncEnqueuing {}

// MARK: - Profile type

/// UI-facing profile kind. Mirrors the `profiles.type` CHECK enum
/// (`'personal' | 'business'`). Drives the conditional ABN/GST fields and the
/// default accent suggestion.
enum ProfileType: String, CaseIterable, Identifiable {
    case personal
    case business
    var id: String { rawValue }
    var label: String { self == .personal ? "Personal" : "Business" }
    var iconName: String { self == .personal ? "wallet" : "building" }
}

// MARK: - Accent swatches

/// One of the 8 selectable accent palettes (the `AP_ACCENTS` set).
/// `base/soft/deep` are the persisted hex strings (`profiles.accent_1/2/3`);
/// `palette` is the runtime `AccentPalette`. The first two swatches REFERENCE the
/// canonical Task-2 presets (`AccentPalette.personal` / `.business`) so the
/// terracotta + teal triads are defined once, in the design system.
struct AccentSwatch: Identifiable, Equatable {
    let id: String
    let name: String
    let base: String   // hex "#RRGGBB"
    let soft: String
    let deep: String
    /// Runtime palette. For the first two swatches this is the canonical Task-2
    /// preset; for the rest it is derived from the hex strings above.
    let palette: AccentPalette
}

/// Parse "#E8602C" -> 0xE8602C for `Color(hex:)`.
func hex(_ s: String) -> UInt32 {
    UInt32(s.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0
}

// MARK: - Accent hex single-source

/// Hex-string forms of the canonical Task-2 presets. The `Color` triads live in
/// `AccentPalette.personal` / `.business`; these are the matching persisted
/// `accent_1/2/3` strings (same values, string form) so nothing is re-hardcoded
/// in two unrelated places.
extension AccentPalette {
    static let personalHexes = (base: "#E8602C", soft: "#FDEBE0", deep: "#C2461A")
    static let businessHexes = (base: "#0E7C72", soft: "#DCF0ED", deep: "#0A5950")
}

/// The 8 production accent palettes. Personal terracotta is index 0 (default for
/// a fresh Personal profile); Business teal is index 1. The first two reference the
/// canonical `AccentPalette.personal` / `.business` presets; the other six are
/// declared here.
let AP_ACCENTS: [AccentSwatch] = [
    .init(id: "terracotta", name: "Terracotta",
          base: AccentPalette.personalHexes.base,
          soft: AccentPalette.personalHexes.soft,
          deep: AccentPalette.personalHexes.deep,
          palette: .personal),
    .init(id: "teal", name: "Teal",
          base: AccentPalette.businessHexes.base,
          soft: AccentPalette.businessHexes.soft,
          deep: AccentPalette.businessHexes.deep,
          palette: .business),
    swatch(id: "indigo", name: "Indigo", base: "#3F5BB0", soft: "#E7EAF8", deep: "#2C4290"),
    swatch(id: "forest", name: "Forest", base: "#2F7A55", soft: "#DFF0E6", deep: "#205B3D"),
    swatch(id: "violet", name: "Violet", base: "#7B5BD6", soft: "#EBE5F8", deep: "#5C3FB0"),
    swatch(id: "ocean",  name: "Ocean",  base: "#2F6FB0", soft: "#E2ECF6", deep: "#1F4E80"),
    swatch(id: "rose",   name: "Rose",   base: "#B0568F", soft: "#F4E4EF", deep: "#854069"),
    swatch(id: "amber",  name: "Amber",  base: "#C99A22", soft: "#F6EECE", deep: "#9A7314"),
]

/// Build an `AccentSwatch` whose `palette` is derived from its hex strings.
private func swatch(id: String, name: String, base: String, soft: String, deep: String) -> AccentSwatch {
    AccentSwatch(
        id: id, name: name, base: base, soft: soft, deep: deep,
        palette: AccentPalette(
            base: Color(hex: hex(base)),
            soft: Color(hex: hex(soft)),
            deep: Color(hex: hex(deep))
        )
    )
}

/// Default swatch for a profile type (Personal -> terracotta, Business -> teal).
func defaultSwatch(for type: ProfileType) -> AccentSwatch {
    type == .personal ? AP_ACCENTS[0] : AP_ACCENTS[1]
}

// MARK: - ProfilesStore

/// Active-profile + profile-list state, backed by SwiftData. `activeProfileId`
/// is persisted to UserDefaults ("sc.activeProfile"); `accent` is derived from
/// the active profile's palette and drives the app-wide `\.accent` environment.
@Observable
@MainActor
final class ProfilesStore {
    @ObservationIgnored let context: ModelContext
    @ObservationIgnored private let sync: any SyncEnqueuing
    /// The signed-in user's id (used to scope fetches and to build child view-models
    /// such as the AddProfile form presented from the shell).
    @ObservationIgnored private(set) var userId: String
    @ObservationIgnored private static let activeKey = "sc.activeProfile"

    /// All non-deleted profiles for the signed-in user, sorted for display.
    private(set) var profiles: [Profile] = []
    var activeProfileId: String {
        didSet { UserDefaults.standard.set(activeProfileId, forKey: Self.activeKey) }
    }

    init(context: ModelContext, sync: any SyncEnqueuing, userId: String) {
        self.context = context
        self.sync = sync
        self.userId = userId
        self.activeProfileId = UserDefaults.standard.string(forKey: Self.activeKey) ?? ""
        reload()
        // Default to the first/default profile if no valid active id is set.
        if profiles.first(where: { $0.id == activeProfileId }) == nil {
            activeProfileId = profiles.first(where: { $0.isDefault })?.id
                ?? profiles.first?.id ?? ""
        }
    }

    /// Re-read profiles from SwiftData (call after add/import/sync).
    func reload() {
        let uid = userId
        let descriptor = FetchDescriptor<Profile>(
            predicate: #Predicate { $0.userId == uid && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
        )
        profiles = (try? context.fetch(descriptor)) ?? []
    }

    /// Re-scope to the live session's user (e.g. after an in-session sign-in) and reload.
    /// Always reloads + re-resolves the active profile, even when the user is unchanged.
    func rescope(to newUserId: String) {
        if newUserId != userId { userId = newUserId }
        reload()
        if profiles.first(where: { $0.id == activeProfileId }) == nil {
            activeProfileId = profiles.first(where: { $0.isDefault })?.id
                ?? profiles.first?.id ?? ""
        }
    }

    var activeProfile: Profile? {
        profiles.first(where: { $0.id == activeProfileId })
    }

    /// Accent palette for the active profile, parsed from its stored hexes.
    /// Falls back to personal terracotta when there is no active profile.
    var accent: AccentPalette {
        guard let p = activeProfile else { return AP_ACCENTS[0].palette }
        return AccentPalette(
            base: Color(hex: hex(p.accent1)),
            soft: Color(hex: hex(p.accent2)),
            deep: Color(hex: hex(p.accent3))
        )
    }

    /// Switch the active profile (no-op for an unknown id).
    func setActive(_ id: String) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeProfileId = id
    }

    /// Insert a profile, refresh the list, enqueue a sync upsert, and activate it.
    func add(_ p: Profile) {
        context.insert(p)
        try? context.save()
        reload()
        sync.enqueue(op: "upsert", entityType: .profile, entity: p)
        TaxSettingsSeeder.ensure(profileId: p.id, userId: userId, context: context, sync: sync)
        setActive(p.id)
    }

    /// Mutate a profile in a closure, stamp updatedAt, persist, reload, enqueue upsert.
    func update(_ profile: Profile, _ mutate: (Profile) -> Void) {
        mutate(profile)
        profile.updatedAt = Epoch.nowMs()
        try? context.save()
        reload()
        sync.enqueue(op: "upsert", entityType: .profile, entity: profile)
    }

    /// Soft-delete a profile. Refuses the last remaining profile or the active one
    /// (the caller must switch away first). Returns true when it deleted.
    @discardableResult
    func delete(_ profile: Profile) -> Bool {
        guard profiles.count > 1 else { return false }
        guard profile.id != activeProfileId else { return false }
        profile.deletedAt = Epoch.nowMs()
        profile.updatedAt = Epoch.nowMs()
        try? context.save()
        reload()
        sync.enqueue(op: "delete", entityType: .profile, entity: profile)
        return true
    }

    /// The active profile's FY start month (1-12) from its tax_settings; 7 (July) if none.
    func activeFinancialYearStartMonth() -> Int {
        let pid = activeProfileId
        var d = FetchDescriptor<TaxSettings>(predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first?.financialYearStartMonth ?? 7
    }
}
