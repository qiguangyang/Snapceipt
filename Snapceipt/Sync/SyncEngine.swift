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

    init(api: APIClient, context: ModelContext, auth: AuthStore, toast: ToastCenter) {
        self.api = api
        self.context = context
        self.auth = auth
        self.toast = toast
    }

    // MARK: enqueue

    /// Append an outbox mutation snapshotting `entity` (full camelCase payload for
    /// an upsert; the snapshot still carries the id for a delete) and mark it pending.
    func enqueue(op: String, entityType: EntityType, entity: any Syncable) {
        let payload = registry.encodePayload(entityType: entityType, entity: entity)
        let mutation = OutboxMutation(
            mutationId: ID.uuidv7(),
            entityType: entityType.rawValue,
            entityId: entity.id,
            op: op,
            payloadJSON: payload,
            baseRev: entity.rev,
            createdAt: Epoch.nowMs(),
            attemptCount: 0,
            status: "pending"
        )
        context.insert(mutation)
        try? context.save()
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
                try? context.save()
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
                toast.show("Updated on another device", kind: .info)
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
            try? context.save()

            // Persist only after the page committed (crash-safe).
            if let next = resp.nextCursor {
                UserDefaults.standard.set(next, forKey: cursorKey)
                cursor = next
            }

            if !resp.hasMore { break }
        }
        status = .idle
    }

    private func applyPulled(_ env: PullChange) {
        guard let entityType = EntityType(rawValue: env.type),
              let handler = registry.handler(for: entityType) else { return }
        let id = env.id
        let incomingUpdatedAt = env.updatedAt

        // Keep local if an unsynced (pending/inflight) outbox edit exists for this id.
        if hasUnsyncedOutbox(entityId: id) { return }

        // LWW: an equal-or-newer local row wins over the incoming change.
        if let localUpd = handler.localUpdatedAt(context, id), localUpd >= incomingUpdatedAt {
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
        return (try? context.fetch(descriptor)) ?? []
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
