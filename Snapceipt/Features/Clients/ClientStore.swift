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
        guard name.count <= 200 else { throw ValidationError.nameTooLong }
        guard (notes?.count ?? 0) <= 10_000 else { throw ValidationError.notesTooLong }
        let client: Client
        if let id { client = try liveClient(id) }
        else {
            client = Client(userId: userId, profileId: profileId, name: name)
            context.insert(client)
        }
        let previous = ClientDraft(name: client.name, email: client.email, mobilePhone: client.mobilePhone,
                                   address: client.address, notes: client.notes)
        let updatedAt = client.updatedAt
        client.name = name
        client.email = normalized(draft.email, trim: .whitespaces)
        client.mobilePhone = normalized(draft.mobilePhone, trim: .whitespaces)
        client.address = normalized(draft.address, trim: .whitespacesAndNewlines)
        client.notes = notes
        client.updatedAt = Epoch.nowMs()
        do { try persist(context) }
        catch {
            // Restore only this operation, preserving other unsaved editor work.
            if id == nil { context.delete(client) }
            else {
                client.name = previous.name; client.email = previous.email
                client.mobilePhone = previous.mobilePhone; client.address = previous.address
                client.notes = previous.notes; client.updatedAt = updatedAt
            }
            throw error
        }
        sync.enqueue(op: "upsert", entityType: .client, entity: client)
        return client
    }

    func delete(id: String) throws {
        let client = try liveClient(id)
        let uid = userId, pid = profileId
        let followUps = try context.fetch(FetchDescriptor<ClientFollowUp>(predicate: #Predicate {
            $0.userId == uid && $0.profileId == pid && $0.clientId == id && $0.deletedAt == nil
        }))
        let previousClientTime = client.updatedAt
        let previousFollowUpTimes = followUps.map(\.updatedAt)
        let now = Epoch.nowMs()
        client.deletedAt = now; client.updatedAt = now
        for followUp in followUps { followUp.deletedAt = now; followUp.updatedAt = now }
        do { try persist(context) }
        catch {
            client.deletedAt = nil; client.updatedAt = previousClientTime
            for (followUp, updatedAt) in zip(followUps, previousFollowUpTimes) {
                followUp.deletedAt = nil; followUp.updatedAt = updatedAt
            }
            throw error
        }
        sync.enqueue(op: "delete", entityType: .client, entity: client)
        for followUp in followUps { sync.enqueue(op: "delete", entityType: .clientFollowUp, entity: followUp) }
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

    private func liveClient(_ id: String) throws -> Client {
        let uid = userId, pid = profileId
        var descriptor = FetchDescriptor<Client>(predicate: #Predicate {
            $0.id == id && $0.userId == uid && $0.profileId == pid && $0.deletedAt == nil
        })
        descriptor.fetchLimit = 1
        guard let client = try context.fetch(descriptor).first else { throw ValidationError.unavailable }
        return client
    }

    private func normalized(_ value: String?, trim: CharacterSet) -> String? {
        let value = value?.trimmingCharacters(in: trim)
        return (value?.isEmpty ?? true) ? nil : value
    }
}
