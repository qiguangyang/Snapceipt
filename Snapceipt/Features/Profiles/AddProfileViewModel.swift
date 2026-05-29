import Foundation
import SwiftData

/// Drives the AddProfile form (type, name, ABN, GST, accent swatch) and the
/// two-step form -> success flow. `create()` builds a `Profile`, persists +
/// enqueues it through `ProfilesStore.add`, and activates it.
@Observable
@MainActor
final class AddProfileViewModel {
    @ObservationIgnored private let store: ProfilesStore
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let userId: String

    var type: ProfileType = .personal {
        didSet { if !userPickedSwatch { swatch = defaultSwatch(for: type) } }
    }
    var name: String = ""
    var abn: String = ""
    var gstRegistered: Bool = false
    var swatch: AccentSwatch = defaultSwatch(for: .personal) {
        didSet { userPickedSwatch = true }
    }
    /// Set once the user changes the accent so the type-default stops overriding.
    @ObservationIgnored private var userPickedSwatch = false

    /// Step-machine: false = form, true = success screen.
    private(set) var didCreate = false
    private(set) var createdProfile: Profile?

    init(store: ProfilesStore, context: ModelContext, userId: String) {
        self.store = store
        self.context = context
        self.userId = userId
    }

    /// Valid when the trimmed name is non-empty.
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Up to two uppercase initials derived from the entered name.
    var derivedInitials: String {
        let words = name.split(separator: " ").prefix(2)
        let chars = words.compactMap { $0.first }.map { String($0).uppercased() }
        return chars.joined()
    }

    /// Build + persist the profile. Returns nil (and no-ops) when invalid.
    @discardableResult
    func create() -> Profile? {
        guard isValid else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Epoch.nowMs()
        let isBusiness = type == .business

        let p = Profile(
            userId: userId,
            name: trimmed,
            type: type.rawValue,
            initials: derivedInitials,
            accent1: swatch.base,
            accent2: swatch.soft,
            accent3: swatch.deep,
            // ABN/GST are Business-only (personal profiles hide tax identity, §3.2).
            abn: isBusiness ? abn.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty : nil,
            gstRegistered: isBusiness ? gstRegistered : false,
            sortOrder: store.profiles.count,
            isDefault: store.profiles.isEmpty,
            createdAt: now,
            updatedAt: now
        )

        store.add(p)            // persists + enqueues sync + activates
        createdProfile = p
        didCreate = true
        return p
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
