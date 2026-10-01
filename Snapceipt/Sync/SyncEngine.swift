import Foundation
import SwiftData
import Observation
import os

/// Coarse sync state surfaced to `SyncStatusView` / `OfflineBanner`.
enum SyncStatus: Equatable {
    case idle
    case syncing
    case offline
    case error(String)
}

// MARK: - Entity glue

/// Per-entity-type glue so the generic engine can apply pulled envelopes and stamp
/// server revisions onto strongly-typed `@Model` rows. The closures capture a
/// concrete `SyncRowMapper`.
struct SyncEntityHandler {
    /// Apply a pulled envelope: find-or-create the row by id, copy domain fields.
    let applyPulled: (_ context: ModelContext, _ env: PullChange) -> Void
    /// Local `updatedAt` for the row id, or nil if no local row exists.
    let localUpdatedAt: (_ context: ModelContext, _ id: String) -> Int?
    /// Local server revision; older pulled revisions must never replace it.
    let localRev: (_ context: ModelContext, _ id: String) -> Int?
    /// Delete the local row for the id (tombstone handling).
    let deleteLocal: (_ context: ModelContext, _ id: String) -> Void
    /// Overwrite the local row from a server entity (push conflict).
    let overwriteLocal: (_ context: ModelContext, _ env: PullChange) -> Void
    /// Stamp server rev + updatedAt onto the local row (push applied/duplicate).
    let stampServer: (_ context: ModelContext, _ id: String, _ rev: Int, _ updatedAt: Int) -> Void
    /// Snapshot a local row's full domain payload (camelCase) for the outbox.
    let encodePayload: (_ entity: any Syncable) -> [String: JSONValue]
}

// MARK: - SyncEngine

/// Drains the offline outbox to the backend and reconciles server deltas into the
/// local SwiftData store, local-first and last-write-wins. Constructed with an
/// injected `APIClient`, `ModelContext`, `AuthStore`, and `ToastCenter`.
@Observable
@MainActor
final class SyncEngine {
    private(set) var status: SyncStatus = .idle

    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let auth: AuthStore
    @ObservationIgnored private let toast: ToastCenter
    @ObservationIgnored private let registry = SyncEntityRegistry.shared
    @ObservationIgnored private let log = Logger(subsystem: "app.snapceipt", category: "sync")

    @ObservationIgnored private let cursorKey = "sc.syncCursor"
    @ObservationIgnored private let pushBatchSize = 200
    @ObservationIgnored private let pullLimit = 500

    /// Serializes `sync()` runs so overlapping triggers don't issue concurrent
    /// authenticated calls. Holds the in-flight full-sync Task, if any.
    @ObservationIgnored private var syncTask: Task<Void, Never>?

    /// Auto-retry after a transient (network / 5xx / 429 / timeout) sync failure. Without this
    /// a single blip leaves a sticky `.offline` that only clears when the user reopens the app;
    /// the retry self-heals it in seconds. Backoff in seconds; reset to the start on success.
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryAttempt = 0
    @ObservationIgnored private let retryBackoff: [Double]

    init(api: APIClient, context: ModelContext, auth: AuthStore, toast: ToastCenter,
         retryBackoff: [Double] = [3, 10, 30, 60]) {
        self.api = api
        self.context = context
        self.auth = auth
        self.toast = toast
        self.retryBackoff = retryBackoff
    }

    // MARK: enqueue

    /// Append an outbox mutation snapshotting `entity` (full camelCase payload for
    /// an upsert; the snapshot still carries the id for a delete) and mark it pending.
    func enqueue(op: String, entityType: EntityType, entity: any Syncable) {
        enqueue(op: op, entityType: entityType, entity: entity, context: context)
    }

    /// Used by isolated domain transactions so outbox saves do not commit shared editor input.
    func enqueue(op: String, entityType: EntityType, entity: any Syncable, context: ModelContext) {
        // Keep the existing best-effort API compatible; checked domain transactions use
        // persistAndEnqueue below so a staging/save failure reaches their UI.
        try? persistAndEnqueue(mutations: [SyncMutationDescriptor(op: op, entityType: entityType, entity: entity)],
                              context: context, save: { try $0.save() })
    }

    /// Stage all sync rows without saving, then commit domain and outbox changes once.
    func persistAndEnqueue(mutations: [SyncMutationDescriptor], context: ModelContext,
                           save: (ModelContext) throws -> Void) throws {
        for mutation in mutations {
            try stage(op: mutation.op, entityType: mutation.entityType, entity: mutation.entity, context: context)
        }
        try save(context)
    }

    private func stage(op: String, entityType: EntityType, entity: any Syncable, context: ModelContext) throws {
        let payload = registry.encodePayload(entityType: entityType, entity: entity)
        // UUIDv7 random bits and millisecond ties cannot preserve insertion order.
        // Allocate a strictly increasing local outbox time; domain timestamps remain unchanged.
        var newest = FetchDescriptor<OutboxMutation>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        newest.fetchLimit = 1
        let latest = try context.fetch(newest).first?.createdAt
        let enqueueTime = max(Epoch.nowMs(), latest.map { $0 + 1 } ?? 0)
        // Dedupe consecutive PENDING upserts for the same entity into ONE row (refresh the payload
        // to the latest state, keep the original baseRev). Otherwise N rapid edits enqueue N upserts
        // all on the same baseRev — the first applies (server rev → R+1) and every later one
        // CONFLICTS (stale baseRev), and the conflict path overwrites local from the server,
        // reverting the later edits (the business-profile phone/website/address revert bug).
        if op == "upsert" {
            let eid = entity.id
            let etype = entityType.rawValue
            var existingDescriptor = FetchDescriptor<OutboxMutation>(predicate: #Predicate {
                $0.entityId == eid && $0.entityType == etype && $0.op == "upsert" && $0.status == "pending"
            })
            existingDescriptor.fetchLimit = 1
            if let existing = try context.fetch(existingDescriptor).first {
                existing.payloadJSON = payload
                // Keep the original FIFO position and base revision. Push resolves
                // any newly assigned pending parent before splitting into batches.
                return
            }
        }
        let mutation = OutboxMutation(
            mutationId: ID.uuidv7(),
            entityType: entityType.rawValue,
            entityId: entity.id,
            op: op,
            payloadJSON: payload,
            baseRev: entity.rev,
            createdAt: enqueueTime,
            attemptCount: 0,
            status: "pending"
        )
        context.insert(mutation)
    }

    // MARK: push

    /// Drain pending outbox rows in batches (≤200) and reconcile each result.
    func push() async {
        // Crash recovery: a previous process died mid-push (after marking a batch
        // "inflight" but before/while on the wire), stranding those rows forever —
        // pendingOutbox only selects "pending". push() is serialized via sync(), so
        // a blanket requeue of every inflight row at the start of a run is safe.
        requeueStrandedInflight()

        let pending = pendingOutbox()
        guard !pending.isEmpty else { return }
        status = .syncing
        let deviceId = auth.deviceId

        for batch in pending.chunked(into: pushBatchSize) {
            // Mark in-flight so a concurrent pull treats these ids as "keep local".
            for m in batch { m.status = "inflight"; m.attemptCount += 1 }
            try? context.save()

            let wire = batch.map { m in
                PushMutation(
                    mutationId: m.mutationId,
                    entityType: m.entityType,
                    entityId: m.entityId,
                    op: m.op,
                    baseRev: m.baseRev,
                    updatedAt: localUpdatedAt(for: m) ?? m.createdAt,
                    payload: AnyEncodable(registry.decodePayload(m.payloadJSON))
                )
            }

            do {
                let resp = try await api.syncPush(deviceId: deviceId, mutations: wire)
                applyPushResults(resp.results, batch: batch)
                do {
                    try context.save()
                    NotificationCenter.default.post(name: .syncDidApplyChanges, object: self)
                } catch {
                    status = .error("Could not save synced changes.")
                    return
                }
            } catch {
                // A deterministic 4xx contract rejection (excluding 401, which the
                // APIClient already refresh-retries, and 429, which is transient)
                // will never succeed on retry: mark the batch failed so it stops
                // blocking the outbox head, and surface a real error state instead
                // of masquerading as offline and silently retrying forever.
                if let apiError = error as? APIError,
                   (400..<500).contains(apiError.status),
                   apiError.status != 401, apiError.status != 408, apiError.status != 429 {
                    for m in batch where m.status == "inflight" { m.status = "failed" }
                    try? context.save()
                    log.error("sync push rejected (\(apiError.status)) \(apiError.code): \(apiError.message)")
                    status = .error(apiError.message)
                    return
                }
                // Network/transport failure (or 5xx/429): roll in-flight back to
                // pending and stop.
                for m in batch where m.status == "inflight" { m.status = "pending" }
                try? context.save()
                status = .offline
                return
            }
        }
        status = .idle
    }

    private func applyPushResults(_ results: [PushResult], batch: [OutboxMutation]) {
        let byId = Dictionary(batch.map { ($0.mutationId, $0) }, uniquingKeysWith: { a, _ in a })
        for r in results {
            guard let m = byId[r.mutationId] else { continue }
            guard let entityType = EntityType(rawValue: m.entityType),
                  let handler = registry.handler(for: entityType) else {
                context.delete(m); continue
            }
            switch r.status {
            case "applied", "duplicate":
                if let env = r.entity {
                    handler.stampServer(context, m.entityId, env.rev, env.updatedAt)
                }
                context.delete(m)
            case "conflict":
                if let env = r.entity {
                    handler.overwriteLocal(context, env)
                }
                context.delete(m)
                toast.show("Synced", kind: .success)   // green check, not a wordy reminder
            default: // "rejected" or unknown
                m.status = "failed"
            }
        }
    }

    // MARK: pull

    /// Loop `syncPull` from the persisted cursor until `hasMore == false`, applying
    /// LWW per change and persisting `nextCursor` after each page (crash-safe).
    func pull() async {
        status = .syncing
        // Older apps can advance past unfamiliar types. Complete one full pull per
        // user after expanding the registry; a failed/interrupted upgrade starts over.
        let versionKey = auth.session.map { "sc.syncEntityVersion." + $0.userId }
        let upgrading = versionKey.map { UserDefaults.standard.integer(forKey: $0) != 20 } ?? false
        if upgrading { UserDefaults.standard.removeObject(forKey: cursorKey) }
        var cursor = UserDefaults.standard.string(forKey: cursorKey)

        while true {
            let resp: PullResponse
            do {
                resp = try await api.syncPull(cursor: cursor, limit: pullLimit)
            } catch {
                status = .offline
                return
            }

            for change in resp.changes {
                applyPulled(change)
            }
            do {
                try context.save()
                NotificationCenter.default.post(name: .syncDidApplyChanges, object: self)
            } catch {
                status = .error("Could not save synced changes.")
                return
            }

            // Persist only after the page committed (crash-safe).
            if let next = resp.nextCursor {
                UserDefaults.standard.set(next, forKey: cursorKey)
                cursor = next
            }

            if !resp.hasMore { break }
        }
        if upgrading, let versionKey {
            UserDefaults.standard.set(20, forKey: versionKey)
        }
        status = .idle
        // Signal screens whose lists are manual fetches (not @Query) to re-read after a pull,
        // so a just-synced email-in receipt appears without relying on a push arriving.
        NotificationCenter.default.post(name: .emailInReceiptArrived, object: nil)
    }

    private func applyPulled(_ env: PullChange) {
        guard let entityType = EntityType(rawValue: env.type),
              let handler = registry.handler(for: entityType) else { return }
        let id = env.id
        let incomingUpdatedAt = env.updatedAt

        // Keep local if an unsynced (pending/inflight) outbox edit exists for this id.
        if hasUnsyncedOutbox(entityId: id) { return }

        // Applied acknowledgements stamp updatedAt/rev without copying domain
        // fields. An authoritative pull at that same timestamp must still apply
        // (for example, a preserved server PDF/status omitted from the push).
        // Pending/inflight edits remain protected above; older timestamps and
        // revisions remain stale even when the other value happens to be newer.
        if let localUpd = handler.localUpdatedAt(context, id), localUpd > incomingUpdatedAt {
            return
        }
        if let localRev = handler.localRev(context, id), localRev > env.rev {
            return
        }

        if env.deletedAt != nil {
            handler.deleteLocal(context, id)
        } else {
            handler.applyPulled(context, env)
        }
    }

    // MARK: sync

    /// Full cycle: push local changes, then pull server deltas. Serialized — a call
    /// while a sync is already in flight awaits and reuses that run rather than
    /// issuing a second concurrent set of authenticated calls.
    func sync() async {
        if let inFlight = syncTask {
            await inFlight.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.push()
            // A push contract rejection sets .error — let it stay visible instead
            // of letting pull() immediately clobber it back to .idle.
            if case .error = self.status { return }
            await self.pull()
        }
        syncTask = task
        await task.value
        syncTask = nil
        scheduleRetryIfNeeded()
    }

    /// After every `sync()` cycle: if it ended `.offline` (a transient failure), schedule an
    /// automatic retry with backoff so the app self-heals without the user reopening it; any
    /// other terminal state cancels the pending retry and resets the backoff. This is what
    /// turns a sticky "Offline" pill into a few-seconds blip. Also re-armed by a foreground or
    /// reachability-return `sync()` (each runs this on completion).
    private func scheduleRetryIfNeeded() {
        guard status == .offline else {
            retryAttempt = 0
            retryTask?.cancel()
            retryTask = nil
            return
        }
        retryTask?.cancel()
        let delay = retryBackoff[min(retryAttempt, retryBackoff.count - 1)]
        retryAttempt += 1
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            await self.sync()
        }
    }

    /// Force the outbox up to the backend NOW and await it — used before an action
    /// endpoint that needs a just-enqueued entity to already exist server-side
    /// (quote send). First awaits any in-flight periodic sync so its batch lands (or
    /// rolls back to pending), then drains a fresh push of whatever remains — which
    /// includes the rows the caller just enqueued. Serialized via `syncTask` exactly
    /// like `sync()`, so a concurrent `sync()`/`flush()` coordinates rather than
    /// issuing a second concurrent push.
    func flush() async {
        if let inFlight = syncTask { await inFlight.value }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.push()
        }
        syncTask = task
        await task.value
        syncTask = nil
    }

    // MARK: outbox queries

    /// Reset stranded "inflight" rows to "pending" (concrete-context #Predicate — safe).
    private func requeueStrandedInflight() {
        let descriptor = FetchDescriptor<OutboxMutation>(
            predicate: #Predicate { $0.status == "inflight" }
        )
        let stranded = (try? context.fetch(descriptor)) ?? []
        guard !stranded.isEmpty else { return }
        for m in stranded { m.status = "pending" }
        try? context.save()
        log.info("requeued \(stranded.count) stranded inflight outbox row(s)")
    }

    private func pendingOutbox() -> [OutboxMutation] {
        let descriptor = FetchDescriptor<OutboxMutation>(
            predicate: #Predicate { $0.status == "pending" },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        let pending = (try? context.fetch(descriptor)) ?? []
        return orderingPendingDependencies(pending)
    }

    /// An older queued document can acquire a newly created client during association.
    /// Resolve those edges over the complete pending snapshot, before the 200-row split.
    /// Move only prerequisites ahead of their dependents; retain FIFO for other rows
    /// and for multiple operations on one entity. Never change persisted queue metadata.
    private func orderingPendingDependencies(_ pending: [OutboxMutation]) -> [OutboxMutation] {
        struct EntityKey: Hashable {
            let type: String
            let id: String
        }
        var firstUpsert: [EntityKey: Int] = [:]
        var previous: [EntityKey: Int] = [:]
        var prerequisites = Array(repeating: [Int](), count: pending.count)
        for (index, row) in pending.enumerated() {
            let key = EntityKey(type: row.entityType, id: row.entityId)
            if let earlier = previous[key] { prerequisites[index].append(earlier) }
            previous[key] = index
            if row.op == "upsert", firstUpsert[key] == nil { firstUpsert[key] = index }
        }
        for (index, row) in pending.enumerated() where row.op == "upsert" {
            // These typed edges are acyclic: client -> document/follow-up -> line.
            // Other payload IDs (including origin links) are not dependencies here.
            let parent: (type: EntityType, field: String)
            switch EntityType(rawValue: row.entityType) {
            case .quote, .invoice, .clientFollowUp: parent = (.client, "clientId")
            case .quoteLineItem: parent = (.quote, "quoteId")
            case .invoiceLineItem: parent = (.invoice, "invoiceId")
            default: continue
            }
            let fields = registry.decodePayload(row.payloadJSON)
            guard let id = fields[parent.field]?.stringValue,
                  let prerequisite = firstUpsert[EntityKey(type: parent.type.rawValue, id: id)] else { continue }
            prerequisites[index].append(prerequisite)
        }
        var ordered: [OutboxMutation] = []
        // Index identity preserves every mutation, even malformed duplicate entity rows.
        // Iterative traversal cannot overflow the stack; visiting nodes break malformed
        // cycles without dropping rows or bypassing the server's normal validation.
        var state = Array(repeating: 0, count: pending.count) // unseen / visiting / emitted
        for index in pending.indices {
            var stack = [(index: index, expanded: false)]
            while let next = stack.popLast() {
                guard state[next.index] != 2 else { continue }
                if next.expanded {
                    state[next.index] = 2
                    ordered.append(pending[next.index])
                } else if state[next.index] == 0 {
                    state[next.index] = 1
                    stack.append((next.index, true))
                    for prerequisite in prerequisites[next.index].reversed() where state[prerequisite] == 0 {
                        stack.append((prerequisite, false))
                    }
                }
            }
        }
        return ordered
    }

    private func hasUnsyncedOutbox(entityId: String) -> Bool {
        let descriptor = FetchDescriptor<OutboxMutation>(
            predicate: #Predicate {
                $0.entityId == entityId && ($0.status == "pending" || $0.status == "inflight")
            }
        )
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    private func localUpdatedAt(for m: OutboxMutation) -> Int? {
        guard let entityType = EntityType(rawValue: m.entityType),
              let handler = registry.handler(for: entityType) else { return nil }
        return handler.localUpdatedAt(context, m.entityId)
    }
}

// MARK: - Array chunking

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
