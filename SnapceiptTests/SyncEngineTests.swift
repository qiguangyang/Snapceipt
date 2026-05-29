import Foundation
import SwiftData
import Testing
@testable import Snapceipt

// MARK: - Helpers

@MainActor
private func makeEngine() throws -> (SyncEngine, ModelContext, MockAPIClient, AuthStore, ToastCenter) {
    let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
    let context = ModelContext(container)
    let api = MockAPIClient()
    let auth = AuthStore()                       // device id auto-generated in Keychain
    let toast = ToastCenter()
    let engine = SyncEngine(api: api, context: context, auth: auth, toast: toast)
    UserDefaults.standard.removeObject(forKey: "sc.syncCursor")
    return (engine, context, api, auth, toast)
}

/// Build a server entity envelope (`PullChange`) by encoding a JSON object and
/// decoding it through `PullChange`'s real `Decodable` path — `PullChange` has a
/// custom `init(from:)` so there is no memberwise initializer to call directly.
private func envelope(
    type: String, id: String, userId: String = "u1",
    rev: Int, updatedAt: Int, createdAt: Int? = nil, deletedAt: Int? = nil,
    extra: [String: Any] = [:]
) -> PullChange {
    var fields: [String: Any] = [
        "type": type,
        "id": id,
        "userId": userId,
        "rev": rev,
        "createdAt": createdAt ?? updatedAt,
        "updatedAt": updatedAt,
        "lastEditedDeviceId": NSNull(),
    ]
    if let deletedAt { fields["deletedAt"] = deletedAt } else { fields["deletedAt"] = NSNull() }
    for (k, v) in extra { fields[k] = v }
    let data = try! JSONSerialization.data(withJSONObject: fields)
    return try! JSONDecoder().decode(PullChange.self, from: data)
}

/// A minimal valid Transaction for tests (the real init has required NOT-NULL fields).
@MainActor
private func makeTxn(userId: String = "u1") -> Transaction {
    Transaction(
        userId: userId,
        profileId: "p1",
        catKey: "meals",
        amountCents: -1234,
        txnDate: "2026-05-01"
    )
}

// MARK: - Tests

@MainActor
@Suite(.serialized)
struct SyncEngineTests {

    @Test func enqueueCreatesPendingOutboxRowWithPayload() throws {
        let (engine, context, _, _, _) = try makeEngine()
        let txn = makeTxn()
        txn.merchant = "The Grounds"
        context.insert(txn)
        engine.enqueue(op: "upsert", entityType: .transaction, entity: txn)

        let outbox = try context.fetch(FetchDescriptor<OutboxMutation>())
        #expect(outbox.count == 1)
        #expect(outbox[0].status == "pending")
        #expect(outbox[0].op == "upsert")
        #expect(outbox[0].entityType == EntityType.transaction.rawValue)
        #expect(outbox[0].entityId == txn.id)
        #expect(outbox[0].payloadJSON.contains("The Grounds"))
    }

    @Test func pushAppliedRemovesOutboxAndBumpsRev() async throws {
        let (engine, context, api, _, _) = try makeEngine()
        let txn = makeTxn()
        txn.rev = 0
        context.insert(txn)
        engine.enqueue(op: "upsert", entityType: .transaction, entity: txn)
        try context.save()

        api.pushHandler = { muts in
            let entity = envelope(type: "transaction", id: muts[0].entityId, rev: 1, updatedAt: 9999)
            return PushResponse(
                results: [PushResult(mutationId: muts[0].mutationId, status: "applied", reason: nil, entity: entity)],
                serverTime: 9999
            )
        }
        await engine.push()

        let outbox = try context.fetch(FetchDescriptor<OutboxMutation>())
        #expect(outbox.isEmpty)
        #expect(txn.rev == 1)
        #expect(txn.updatedAt == 9999)
    }

    @Test func pushConflictOverwritesLocalAndToasts() async throws {
        let (engine, context, api, _, toast) = try makeEngine()
        let txn = makeTxn()
        txn.merchant = "Mine"
        context.insert(txn)
        engine.enqueue(op: "upsert", entityType: .transaction, entity: txn)
        try context.save()

        api.pushHandler = { muts in
            let entity = envelope(
                type: "transaction", id: muts[0].entityId, rev: 5, updatedAt: 8888,
                extra: ["merchant": "Server Wins"]
            )
            return PushResponse(
                results: [PushResult(mutationId: muts[0].mutationId, status: "conflict", reason: nil, entity: entity)],
                serverTime: 8888
            )
        }
        await engine.push()

        #expect(txn.merchant == "Server Wins")
        #expect(txn.rev == 5)
        let outbox = try context.fetch(FetchDescriptor<OutboxMutation>())
        #expect(outbox.isEmpty)
        #expect(toast.current?.message == "Updated on another device")
    }

    @Test func pushRejectedMarksOutboxFailed() async throws {
        let (engine, context, api, _, _) = try makeEngine()
        let txn = makeTxn()
        context.insert(txn)
        engine.enqueue(op: "upsert", entityType: .transaction, entity: txn)
        try context.save()

        api.pushHandler = { muts in
            PushResponse(
                results: [PushResult(mutationId: muts[0].mutationId, status: "rejected", reason: "FORBIDDEN", entity: nil)],
                serverTime: 1
            )
        }
        await engine.push()

        let outbox = try context.fetch(FetchDescriptor<OutboxMutation>())
        #expect(outbox.count == 1)
        #expect(outbox[0].status == "failed")
    }

    @Test func pullUpsertsNewEntity() async throws {
        let (engine, context, api, _, _) = try makeEngine()
        let id = ID.uuidv7()
        api.pullPages = [
            PullResponse(
                changes: [envelope(type: "transaction", id: id, rev: 3, updatedAt: 7000,
                                   extra: ["merchant": "Pulled In", "profileId": "p1",
                                           "catKey": "meals", "amountCents": -500, "txnDate": "2026-05-02"])],
                nextCursor: "CUR1", hasMore: false, serverTime: 7000
            )
        ]
        await engine.pull()

        let rows = try context.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == id }))
        #expect(rows.count == 1)
        #expect(rows[0].merchant == "Pulled In")
        #expect(rows[0].rev == 3)
        #expect(UserDefaults.standard.string(forKey: "sc.syncCursor") == "CUR1")
    }

    @Test func pullTombstoneDeletesLocal() async throws {
        let (engine, context, api, _, _) = try makeEngine()
        let txn = makeTxn()
        txn.updatedAt = 100
        context.insert(txn)
        try context.save()
        let id = txn.id

        api.pullPages = [
            PullResponse(
                changes: [envelope(type: "transaction", id: id, rev: 2, updatedAt: 200, deletedAt: 200)],
                nextCursor: "CUR2", hasMore: false, serverTime: 200
            )
        ]
        await engine.pull()

        let rows = try context.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == id }))
        #expect(rows.isEmpty)
    }

    @Test func pullKeepsLocalWhenPendingOutboxExists() async throws {
        let (engine, context, api, _, _) = try makeEngine()
        let txn = makeTxn()
        txn.merchant = "Local Edit"
        txn.updatedAt = 500
        context.insert(txn)
        engine.enqueue(op: "upsert", entityType: .transaction, entity: txn) // pending outbox row
        try context.save()
        let id = txn.id

        api.pullPages = [
            PullResponse(
                changes: [envelope(type: "transaction", id: id, rev: 9, updatedAt: 9000,
                                   extra: ["merchant": "Server Newer"])],
                nextCursor: "CUR3", hasMore: false, serverTime: 9000
            )
        ]
        await engine.pull()

        let rows = try context.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == id }))
        #expect(rows.count == 1)
        #expect(rows[0].merchant == "Local Edit") // kept local despite newer server change
    }

    @Test func pullLoopsPagesUntilHasMoreFalseAndPersistsLastCursor() async throws {
        let (engine, context, api, _, _) = try makeEngine()
        let idA = ID.uuidv7(), idB = ID.uuidv7()
        api.pullPages = [
            PullResponse(changes: [envelope(type: "transaction", id: idA, rev: 1, updatedAt: 1000,
                                            extra: ["profileId": "p1", "catKey": "meals", "amountCents": -1, "txnDate": "2026-05-01"])],
                         nextCursor: "P1", hasMore: true, serverTime: 1000),
            PullResponse(changes: [envelope(type: "transaction", id: idB, rev: 1, updatedAt: 2000,
                                            extra: ["profileId": "p1", "catKey": "meals", "amountCents": -1, "txnDate": "2026-05-01"])],
                         nextCursor: "P2", hasMore: false, serverTime: 2000),
        ]
        await engine.pull()

        #expect(api.pullCursors == [nil, "P1"]) // second page sent the first page's cursor
        #expect(UserDefaults.standard.string(forKey: "sc.syncCursor") == "P2")
        let rows = try context.fetch(FetchDescriptor<Transaction>())
        #expect(rows.count == 2)
    }

    @Test func syncSerializesOverlappingRunsIntoOne() async throws {
        let (engine, _, api, _, _) = try makeEngine()
        // No pending outbox + no pull pages -> one push (no-op, no call) + one pull
        // call per sync() run. Two *coalesced* runs must issue a single pull call.
        async let a: Void = engine.sync()
        async let b: Void = engine.sync()
        _ = await (a, b)

        // The second sync() coalesced onto the first, so syncPull was called once.
        #expect(api.pullCursors.count == 1)
    }

    @Test func pullUpsertsProfileMappingProfileTypePersona() async throws {
        let (engine, context, api, _, _) = try makeEngine()
        let id = ID.uuidv7()
        // Backend pull envelope: SPINE `type` = "profile" discriminant,
        // `profileType` = the persona ("business").
        api.pullPages = [
            PullResponse(
                changes: [envelope(type: "profile", id: id, rev: 1, updatedAt: 3000,
                                   extra: ["name": "Acme", "profileType": "business",
                                           "accent1": "#0E7C72", "accent2": "#DCF0ED", "accent3": "#0A5950"])],
                nextCursor: "PC1", hasMore: false, serverTime: 3000
            )
        ]
        await engine.pull()

        let rows = try context.fetch(FetchDescriptor<Profile>(predicate: #Predicate { $0.id == id }))
        #expect(rows.count == 1)
        #expect(rows[0].name == "Acme")
        #expect(rows[0].type == "business")   // persona, not the "profile" discriminant
    }
}
