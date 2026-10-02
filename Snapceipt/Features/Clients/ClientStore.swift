import Foundation
import SwiftData

struct ClientDraft {
    var name: String
    var email: String? = nil
    var mobilePhone: String? = nil
    var address: String? = nil
    var notes: String? = nil
}

struct ClientSelection {
    let id: String
    let name: String
    let email: String?
    let mobilePhone: String?
    let address: String?

    init(id: String, name: String, email: String? = nil, mobilePhone: String? = nil, address: String? = nil) {
        self.id = id
        self.name = name
        self.email = email
        self.mobilePhone = mobilePhone
        self.address = address
    }

    init(_ client: Client) {
        self.init(id: client.id, name: client.name, email: client.email,
                  mobilePhone: client.mobilePhone, address: client.address)
    }
}

/// The shared, account/profile-scoped write boundary for the picker and client editor.
/// Contacts are copied onto documents by their editors, never rewritten by this store.
@MainActor
final class ClientStore {
    enum ValidationError: LocalizedError {
        case blankName, nameTooLong, notesTooLong, unavailable, documentUnavailable
        var errorDescription: String? {
            switch self {
            case .blankName: "Enter a client name."
            case .nameTooLong: "Client name must be 200 characters or fewer."
            case .notesTooLong: "Notes must be 10,000 characters or fewer."
            case .unavailable: "This client is no longer available in this business."
            case .documentUnavailable: "A selected document is no longer available or has already been linked. Review your selection."
            }
        }
    }

    let context: ModelContext
    private let sync: any SyncEnqueuing
    let userId: String
    let profileId: String
    private let persist: (ModelContext) throws -> Void

    init(context: ModelContext, sync: any SyncEnqueuing, userId: String, profileId: String,
         persist: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.context = context
        self.sync = sync
        self.userId = userId
        self.profileId = profileId
        self.persist = persist
    }

    func list(search: String) throws -> [Client] {
        let uid = userId, pid = profileId
        let clients = try context.fetch(FetchDescriptor<Client>(
            predicate: #Predicate { $0.userId == uid && $0.profileId == pid && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.name), SortDescriptor(\.createdAt)]))
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return query.isEmpty ? clients : clients.filter {
            $0.name.lowercased().contains(query) || ($0.email?.lowercased().contains(query) ?? false)
        }
    }

    func save(id: String?, draft: ClientDraft) throws -> Client {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = normalized(draft.notes, trim: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ValidationError.blankName }
        guard name.utf16.count <= 200 else { throw ValidationError.nameTooLong }
        guard (notes?.utf16.count ?? 0) <= 10_000 else { throw ValidationError.notesTooLong }
        let isolated = ModelContext(context.container)
        isolated.autosaveEnabled = false
        let client: Client
        let working: Client?
        if let id {
            working = try liveClient(id)
            client = try liveClient(id, in: isolated)
        } else {
            working = nil
            client = Client(userId: userId, profileId: profileId, name: name)
            isolated.insert(client)
        }
        client.name = name
        client.email = normalized(draft.email, trim: .whitespaces)
        client.mobilePhone = normalized(draft.mobilePhone, trim: .whitespaces)
        client.address = normalized(draft.address, trim: .whitespacesAndNewlines)
        client.notes = notes
        client.updatedAt = Epoch.nowMs()
        try sync.persistAndEnqueue(mutations: [.init(op: "upsert", entityType: .client, entity: client)],
                                   context: isolated, save: persist)
        if let working {
            working.name = client.name; working.email = client.email
            working.mobilePhone = client.mobilePhone; working.address = client.address
            working.notes = client.notes; working.updatedAt = client.updatedAt
            return working
        }
        return try liveClient(client.id)
    }

    func delete(id: String) throws {
        let working = try liveClient(id)
        let isolated = ModelContext(context.container)
        isolated.autosaveEnabled = false
        let client = try liveClient(id, in: isolated)
        let uid = userId, pid = profileId
        let descriptor = FetchDescriptor<ClientFollowUp>(predicate: #Predicate {
            $0.userId == uid && $0.profileId == pid && $0.clientId == id && $0.deletedAt == nil
        })
        let followUps = try isolated.fetch(descriptor)
        let workingFollowUps = try context.fetch(descriptor)
        let now = Epoch.nowMs()
        client.deletedAt = now; client.updatedAt = now
        for followUp in followUps { followUp.deletedAt = now; followUp.updatedAt = now }
        let mutations = [SyncMutationDescriptor(op: "delete", entityType: .client, entity: client)]
            + followUps.map { SyncMutationDescriptor(op: "delete", entityType: .clientFollowUp, entity: $0) }
        try sync.persistAndEnqueue(mutations: mutations, context: isolated, save: persist)
        working.deletedAt = now; working.updatedAt = now
        let committedIds = Set(followUps.map(\.id))
        for followUp in workingFollowUps where committedIds.contains(followUp.id) {
            followUp.deletedAt = now; followUp.updatedAt = now
        }
        NotificationCenter.default.post(name: .clientFollowUpsDidChange, object: nil)
    }

    /// Associate only explicitly confirmed records, using committed snapshots for the write.
    /// Both the working context and the persisted rows are rechecked before any mutation.
    func linkExistingDocuments(clientId: String, documents: [ClientHistory.DocumentReference]) throws {
        let workingClient = try liveClient(clientId)
        guard workingClient.userId == userId, workingClient.profileId == profileId, workingClient.deletedAt == nil else {
            throw ValidationError.unavailable
        }
        guard !documents.isEmpty else { return }
        let mutationContext = ModelContext(context.container)
        mutationContext.autosaveEnabled = false
        let uid = userId, pid = profileId
        let clients = try mutationContext.fetch(FetchDescriptor<Client>(predicate: #Predicate {
            $0.id == clientId && $0.userId == uid && $0.profileId == pid && $0.deletedAt == nil
        }))
        guard !clients.isEmpty else { throw ValidationError.unavailable }

        var quotes: [(saved: Quote, working: Quote)] = []
        var invoices: [(saved: Invoice, working: Invoice)] = []
        // Deduplicate selection while retaining a stable order for mutation and sync.
        let selection = Set(documents).sorted {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.id < $1.id
        }
        for reference in selection {
            let id = reference.id
            switch reference.kind {
            case .quote:
                let descriptor = FetchDescriptor<Quote>(predicate: #Predicate { $0.id == id && $0.userId == uid && $0.profileId == pid })
                guard let working = try context.fetch(descriptor).first,
                      let saved = try mutationContext.fetch(descriptor).first,
                      working.userId == uid, working.profileId == pid, working.deletedAt == nil, working.clientId == nil,
                      saved.userId == uid, saved.profileId == pid, saved.deletedAt == nil, saved.clientId == nil else {
                    throw ValidationError.documentUnavailable
                }
                quotes.append((saved, working))
            case .invoice:
                let descriptor = FetchDescriptor<Invoice>(predicate: #Predicate { $0.id == id && $0.userId == uid && $0.profileId == pid })
                guard let working = try context.fetch(descriptor).first,
                      let saved = try mutationContext.fetch(descriptor).first,
                      working.userId == uid, working.profileId == pid, working.deletedAt == nil, working.clientId == nil,
                      saved.userId == uid, saved.profileId == pid, saved.deletedAt == nil, saved.clientId == nil else {
                    throw ValidationError.documentUnavailable
                }
                invoices.append((saved, working))
            }
        }
        let now = Epoch.nowMs()
        for pair in quotes { pair.saved.clientId = clientId; pair.saved.updatedAt = now }
        for pair in invoices { pair.saved.clientId = clientId; pair.saved.updatedAt = now }
        let mutations = quotes.map { SyncMutationDescriptor(op: "upsert", entityType: .quote, entity: $0.saved) }
            + invoices.map { SyncMutationDescriptor(op: "upsert", entityType: .invoice, entity: $0.saved) }
        // Domain links and staged outbox rows share one checked save. Failure discards
        // only this isolated context; pending user input remains intact and unsaved.
        try sync.persistAndEnqueue(mutations: mutations, context: mutationContext, save: persist)
        for pair in quotes { pair.working.clientId = clientId; pair.working.updatedAt = now }
        for pair in invoices { pair.working.clientId = clientId; pair.working.updatedAt = now }
    }

    private func liveClient(_ id: String, in source: ModelContext? = nil) throws -> Client {
        let uid = userId, pid = profileId
        var descriptor = FetchDescriptor<Client>(predicate: #Predicate {
            $0.id == id && $0.userId == uid && $0.profileId == pid && $0.deletedAt == nil
        })
        descriptor.fetchLimit = 1
        guard let client = try (source ?? context).fetch(descriptor).first,
              client.userId == uid, client.profileId == pid, client.deletedAt == nil else { throw ValidationError.unavailable }
        return client
    }

    private func normalized(_ value: String?, trim: CharacterSet) -> String? {
        let value = value?.trimmingCharacters(in: trim)
        return (value?.isEmpty ?? true) ? nil : value
    }
}
