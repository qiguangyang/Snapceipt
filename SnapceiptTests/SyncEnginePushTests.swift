import Foundation
import SwiftData
import Testing
@testable import Snapceipt

// MARK: - Helpers

@MainActor
private func makeEngine() throws -> (SyncEngine, ModelContext, MockAPIClient) {
    let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
    let context = ModelContext(container)
    let api = MockAPIClient()
    let auth = AuthStore()
    let toast = ToastCenter()
    let engine = SyncEngine(api: api, context: context, auth: auth, toast: toast)
    UserDefaults.standard.removeObject(forKey: "sc.syncCursor")
    return (engine, context, api)
}

/// Build a server entity envelope through `PullChange`'s real `Decodable` path.
private func envelope(
    type: String, id: String, userId: String = "u1",
    rev: Int, updatedAt: Int
) -> PullChange {
    let fields: [String: Any] = [
        "type": type, "id": id, "userId": userId,
        "rev": rev, "createdAt": updatedAt, "updatedAt": updatedAt,
        "deletedAt": NSNull(), "lastEditedDeviceId": NSNull(),
    ]
    let data = try! JSONSerialization.data(withJSONObject: fields)
    return try! JSONDecoder().decode(PullChange.self, from: data)
}

@MainActor
private func makeTxn(userId: String = "u1") -> Transaction {
    Transaction(userId: userId, profileId: "p1", catKey: "meals",
                amountCents: -1234, txnDate: "2026-05-01")
}

@MainActor
private func makeProfile(userId: String = "u1") -> Profile {
    Profile(userId: userId, name: "Personal", type: "personal",
            accent1: "#0E7C72", accent2: "#DCF0ED", accent3: "#0A5950")
}

// MARK: - Tests

/// Regression coverage for the push path that crashed on device (0.1.0(1)):
/// the generic protocol-extension `SyncRowMapper.fetch` trapped inside SwiftData
/// before `api.syncPush` was ever called. These tests drive the real enqueue →
/// push pipeline (wire-build calls `localUpdatedAt` → mapper fetch, and applied
/// results call `stampServer` → mapper fetch) for the two entity types from the
/// crash logs, plus the outbox-resilience behaviors layered on top.
@MainActor
@Suite(.serialized)
struct SyncEnginePushTests {

    @Test func pushProfileAndTransactionExercisesGenericFetchWithoutCrashing() async throws {
        let (engine, context, api) = try makeEngine()
        let profile = makeProfile()
        let txn = makeTxn()
        context.insert(profile)
        context.insert(txn)
        engine.enqueue(op: "upsert", entityType: .profile, entity: profile)
        engine.enqueue(op: "upsert", entityType: .transaction, entity: txn)
        try context.save()

        api.pushHandler = { muts in
            PushResponse(
                results: muts.map { m in
                    PushResult(mutationId: m.mutationId, status: "applied", reason: nil,
                               entity: envelope(type: m.entityType, id: m.entityId,
                                                rev: 7, updatedAt: 7777))
                },
                serverTime: 7777
            )
        }
        await engine.push()

        // Both mutations reached the API (the crash killed the app before this).
        #expect(api.pushCalls.count == 1)
        #expect(api.pushCalls[0].count == 2)
        #expect(Set(api.pushCalls[0].map(\.entityType)) == ["profile", "transaction"])
        // Applied → outbox drained, server rev/updatedAt stamped via the generic fetch.
        let outbox = try context.fetch(FetchDescriptor<OutboxMutation>())
        #expect(outbox.isEmpty)
        #expect(profile.rev == 7 && profile.updatedAt == 7777)
        #expect(txn.rev == 7 && txn.updatedAt == 7777)
        #expect(engine.status == .idle)
    }

    @Test func pushRequeuesStrandedInflightRowsAndSendsThem() async throws {
        let (engine, context, api) = try makeEngine()
        let txn = makeTxn()
        context.insert(txn)
        engine.enqueue(op: "upsert", entityType: .transaction, entity: txn)
        // Simulate a crash mid-push: the row was marked inflight, never reset.
        let stranded = try context.fetch(FetchDescriptor<OutboxMutation>())[0]
        stranded.status = "inflight"
        try context.save()

        api.pushHandler = { muts in
            PushResponse(
                results: muts.map { PushResult(mutationId: $0.mutationId, status: "applied",
                                               reason: nil, entity: nil) },
                serverTime: 1
            )
        }
        await engine.push()

        // The stranded row was requeued to pending and pushed in the same run.
        #expect(api.pushCalls.count == 1)
        #expect(api.pushCalls[0].map(\.mutationId) == [stranded.mutationId])
        let outbox = try context.fetch(FetchDescriptor<OutboxMutation>())
        #expect(outbox.isEmpty)
        #expect(engine.status == .idle)
    }

    @Test func push4xxMarksBatchFailedAndSurfacesError() async throws {
        let (engine, context, api) = try makeEngine()
        let txn = makeTxn()
        context.insert(txn)
        engine.enqueue(op: "upsert", entityType: .transaction, entity: txn)
        try context.save()

        api.pushHandler = { _ in
            throw APIError(code: "VALIDATION_FAILED", message: "Invalid payload", status: 400)
        }
        await engine.push()

        // Deterministic contract rejection: failed (not pending), error (not offline).
        let outbox = try context.fetch(FetchDescriptor<OutboxMutation>())
        #expect(outbox.count == 1)
        #expect(outbox[0].status == "failed")
        #expect(engine.status == .error("Invalid payload"))
        #expect(engine.status != .offline)
    }

    @Test func pushTransportFailureKeepsPendingAndGoesOffline() async throws {
        let (engine, context, api) = try makeEngine()
        let txn = makeTxn()
        context.insert(txn)
        engine.enqueue(op: "upsert", entityType: .transaction, entity: txn)
        try context.save()

        api.pushHandler = { _ in throw APIError.transport }
        await engine.push()

        let outbox = try context.fetch(FetchDescriptor<OutboxMutation>())
        #expect(outbox.count == 1)
        #expect(outbox[0].status == "pending") // rolled back for retry
        #expect(engine.status == .offline)
    }

    @Test func enqueuedPayloadCarriesTypeAndOmitsNullLastEditedDeviceId() throws {
        let (engine, context, _) = try makeEngine()
        let txn = makeTxn()
        #expect(txn.lastEditedDeviceId == nil)
        context.insert(txn)
        engine.enqueue(op: "upsert", entityType: .transaction, entity: txn)

        let outbox = try context.fetch(FetchDescriptor<OutboxMutation>())
        #expect(outbox.count == 1)
        let json = try JSONSerialization.jsonObject(
            with: Data(outbox[0].payloadJSON.utf8)) as? [String: Any]
        #expect(json?["type"] as? String == "transaction")
        #expect(json?.keys.contains("lastEditedDeviceId") == false) // omitted, not null
    }
}
