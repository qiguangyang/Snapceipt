import Foundation
import SwiftData
import Observation

/// Drives the bill-to client picker. Loads the active profile's saved clients
/// (name-sorted), supports inline create (+ enqueue upsert). `@MainActor`; deps
/// injected for tests.
@Observable
@MainActor
final class ClientPickerViewModel {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let sync: any SyncEnqueuing
    @ObservationIgnored private let userId: String
    @ObservationIgnored let profileId: String

    /// Active profile's live clients, name-sorted.
    private(set) var clients: [Client] = []

    init(context: ModelContext, sync: any SyncEnqueuing, userId: String, profileId: String) {
        self.context = context
        self.sync = sync
        self.userId = userId
        self.profileId = profileId
        reload()
    }

    func reload() {
        let pid = profileId
        let d = FetchDescriptor<Client>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.name), SortDescriptor(\.createdAt)])
        clients = (try? context.fetch(d)) ?? []
    }

    /// Clients filtered by a case-insensitive name/email substring (blank -> all).
    func filtered(search: String) -> [Client] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return clients }
        return clients.filter {
            $0.name.lowercased().contains(q) || ($0.email?.lowercased().contains(q) ?? false)
        }
    }

    /// Create a client scoped to the active profile (+ enqueue an upsert). Trims
    /// name/email/address; an empty email/address becomes nil. Returns nil for a blank
    /// name. Address is freeform multiline (whitespace+newlines trimmed at the edges).
    @discardableResult
    func create(name: String, email: String?, mobilePhone: String? = nil, address: String? = nil) -> Client? {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return nil }
        let trimmedEmail = email?.trimmingCharacters(in: .whitespaces)
        let normalizedEmail = (trimmedEmail?.isEmpty ?? true) ? nil : trimmedEmail
        let trimmedMobile = mobilePhone?.trimmingCharacters(in: .whitespaces)
        let normalizedMobile = (trimmedMobile?.isEmpty ?? true) ? nil : trimmedMobile
        let trimmedAddress = address?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAddress = (trimmedAddress?.isEmpty ?? true) ? nil : trimmedAddress
        let client = Client(userId: userId, profileId: profileId,
                            name: trimmedName, email: normalizedEmail,
                            mobilePhone: normalizedMobile, address: normalizedAddress)
        context.insert(client)
        try? context.save()
        reload()
        sync.enqueue(op: "upsert", entityType: .client, entity: client)
        return client
    }

    /// Soft-delete a client (+ enqueue a delete). Mirrors InvoiceListViewModel.delete. Sent
    /// quotes/invoices keep their copied name/email/address snapshot, so they're unaffected.
    func delete(_ client: Client) {
        client.deletedAt = Epoch.nowMs()
        client.updatedAt = Epoch.nowMs()
        try? context.save()
        reload()
        sync.enqueue(op: "delete", entityType: .client, entity: client)
    }
}
