import Foundation
import SwiftData

@MainActor
final class ClientFollowUpStore {
    enum ValidationError: LocalizedError {
        case title, date, timestamp, timezone, unavailable
        var errorDescription: String? {
            switch self {
            case .title: "Enter a title of 200 characters or fewer."
            case .date: "Choose a future date and time."
            case .timestamp: "Choose a date and time within the supported range."
            case .timezone: "Choose a valid timezone."
            case .unavailable: "This client or follow-up is no longer available in this business."
            }
        }
    }
    private let context: ModelContext
    private let sync: any SyncEnqueuing
    let userId: String
    let profileId: String
    private let persist: (ModelContext) throws -> Void

    init(context: ModelContext, sync: any SyncEnqueuing, userId: String, profileId: String,
         persist: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.context = context; self.sync = sync; self.userId = userId
        self.profileId = profileId; self.persist = persist
    }

    func list(clientId: String?, includeCompleted: Bool) throws -> [ClientFollowUp] {
        let uid = userId, pid = profileId
        let rows = try context.fetch(FetchDescriptor<ClientFollowUp>(predicate: #Predicate {
            $0.userId == uid && $0.profileId == pid && $0.deletedAt == nil
        }, sortBy: [SortDescriptor(\.dueAt), SortDescriptor(\.id)]))
        let clients = try context.fetch(FetchDescriptor<Client>(predicate: #Predicate {
            $0.userId == uid && $0.profileId == pid && $0.deletedAt == nil
        }))
        let live = Set(clients.map(\.id))
        return rows.filter { live.contains($0.clientId) && (clientId == nil || $0.clientId == clientId)
            && (includeCompleted || $0.completedAt == nil) }
    }

    func save(id: String?, clientId: String, title: String, dueAt: Int, timezone: String, now: Int) throws -> ClientFollowUp {
        try validateTimestamp(now)
        try validateTimestamp(dueAt)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty && title.utf16.count <= 200 else { throw ValidationError.title }
        guard dueAt > now else { throw ValidationError.date }
        guard TimeZone(identifier: timezone) != nil else { throw ValidationError.timezone }
        let isolated = mutationContext()
        try requireClient(clientId, in: context); try requireClient(clientId, in: isolated)
        let row: ClientFollowUp
        let working: ClientFollowUp?
        if let id {
            working = try liveFollowUp(id, in: context)
            row = try liveFollowUp(id, in: isolated)
            guard row.clientId == clientId && working?.clientId == clientId else { throw ValidationError.unavailable }
        } else {
            working = nil
            row = ClientFollowUp(userId: userId, profileId: profileId, clientId: clientId, createdAt: now, updatedAt: now)
            isolated.insert(row)
        }
        row.title = title; row.dueAt = dueAt; row.timezone = timezone; row.updatedAt = now
        try commit(row, op: "upsert", in: isolated)
        if let working {
            working.title = row.title; working.dueAt = row.dueAt; working.timezone = row.timezone
            working.updatedAt = row.updatedAt
            return working
        }
        // Return a committed row from the caller's context, never insert a duplicate.
        return try liveFollowUp(row.id, in: context)
    }

    func complete(id: String, at: Int) throws {
        try validateTimestamp(at)
        try mutate(id: id) { $0.completedAt = at; $0.updatedAt = at }
    }
    func reopen(id: String) throws { try mutate(id: id) { $0.completedAt = nil; $0.updatedAt = Epoch.nowMs() } }
    func delete(id: String) throws { try mutate(id: id, op: "delete") { $0.deletedAt = Epoch.nowMs(); $0.updatedAt = $0.deletedAt! } }

    private func validateTimestamp(_ value: Int) throws {
        guard (0...9_007_199_254_740_991).contains(value) else { throw ValidationError.timestamp }
    }

    private func mutate(id: String, op: String = "upsert", edit: (ClientFollowUp) -> Void) throws {
        let working = try liveFollowUp(id, in: context)
        let isolated = mutationContext()
        let row = try liveFollowUp(id, in: isolated)
        // Deleted clients cannot acquire or reopen reminders. A delete can still clean a stale row.
        if op != "delete" { try requireClient(row.clientId, in: context); try requireClient(row.clientId, in: isolated) }
        edit(row)
        try commit(row, op: op, in: isolated)
        if op == "delete" { working.deletedAt = row.deletedAt }
        else { working.completedAt = row.completedAt }
        working.updatedAt = row.updatedAt
    }
    private func commit(_ row: ClientFollowUp, op: String, in isolated: ModelContext) throws {
        try sync.persistAndEnqueue(mutations: [.init(op: op, entityType: .clientFollowUp, entity: row)], context: isolated, save: persist)
        NotificationCenter.default.post(name: .clientFollowUpsDidChange, object: nil)
    }
    private func mutationContext() -> ModelContext {
        let c = ModelContext(context.container); c.autosaveEnabled = false; return c
    }
    private func requireClient(_ id: String, in c: ModelContext) throws {
        let uid = userId, pid = profileId
        let rows = try c.fetch(FetchDescriptor<Client>(predicate: #Predicate {
            $0.id == id && $0.userId == uid && $0.profileId == pid && $0.deletedAt == nil
        }))
        guard rows.first.map({ $0.deletedAt == nil && $0.userId == uid && $0.profileId == pid }) == true else { throw ValidationError.unavailable }
    }
    private func liveFollowUp(_ id: String, in c: ModelContext) throws -> ClientFollowUp {
        let uid = userId, pid = profileId
        let rows = try c.fetch(FetchDescriptor<ClientFollowUp>(predicate: #Predicate {
            $0.id == id && $0.userId == uid && $0.profileId == pid && $0.deletedAt == nil
        }))
        guard let row = rows.first, row.deletedAt == nil, row.userId == uid, row.profileId == pid else { throw ValidationError.unavailable }
        return row
    }

}

extension Notification.Name {
    static let clientFollowUpsDidChange = Notification.Name("clientFollowUpsDidChange")
    static let syncDidApplyChanges = Notification.Name("syncDidApplyChanges")
}
