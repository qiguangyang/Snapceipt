import Foundation
import SwiftData
import Testing
@testable import Snapceipt

@MainActor
private func makeEngine() throws -> (SyncEngine, ModelContext, MockAPIClient) {
    let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
    let context = ModelContext(container)
    let api = MockAPIClient()
    let engine = SyncEngine(api: api, context: context, auth: AuthStore(), toast: ToastCenter())
    UserDefaults.standard.removeObject(forKey: "sc.syncCursor")
    return (engine, context, api)
}

private func envelope(type: String, id: String, rev: Int, updatedAt: Int,
                      extra: [String: Any]) -> PullChange {
    var fields: [String: Any] = ["type": type, "id": id, "userId": "u1", "rev": rev,
                                 "createdAt": updatedAt, "updatedAt": updatedAt,
                                 "deletedAt": NSNull(), "lastEditedDeviceId": NSNull()]
    for (k, v) in extra { fields[k] = v }
    let data = try! JSONSerialization.data(withJSONObject: fields)
    return try! JSONDecoder().decode(PullChange.self, from: data)
}

@MainActor
@Suite(.serialized)
struct BasSyncTests {
    @Test func transactionPayloadCarriesBasColumns() throws {
        let (engine, context, _) = try makeEngine()
        let t = Transaction(userId: "u1", profileId: "p1", catKey: "groceries",
                            amountCents: -33_000, txnDate: "2026-04-01",
                            gstFree: true, capital: false, gstSource: nil)
        context.insert(t)
        engine.enqueue(op: "upsert", entityType: .transaction, entity: t)
        let outbox = try context.fetch(FetchDescriptor<OutboxMutation>())
        #expect(outbox[0].payloadJSON.contains("\"gstFree\":true"))
        #expect(outbox[0].payloadJSON.contains("\"capital\":false"))
        #expect(outbox[0].payloadJSON.contains("\"gstSource\":null"))
    }

    @Test func transactionPullAppliesBasColumns() async throws {
        let (engine, context, api) = try makeEngine()
        let id = ID.uuidv7()
        api.pullPages = [PullResponse(
            changes: [envelope(type: "transaction", id: id, rev: 2, updatedAt: 9000,
                               extra: ["profileId": "p1", "catKey": "office", "amountCents": -220_000,
                                       "txnDate": "2026-04-05", "gstFree": false, "capital": true,
                                       "gstSource": "manual"])],
            nextCursor: "C1", hasMore: false, serverTime: 9000)]
        await engine.pull()
        let row = try context.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == id })).first!
        #expect(row.capital == true)
        #expect(row.gstFree == false)
        #expect(row.gstSource == "manual")
    }

    @Test func categoryRoundTripsGstFreeDefault() async throws {
        let (engine, context, api) = try makeEngine()
        let c = Snapceipt.Category(userId: "u1", profileId: "p1", key: "groceries", label: "Groceries",
                                   icon: "tag", tint: "#C99A22", soft: "#F6EECE", gstFreeDefault: true)
        context.insert(c)
        engine.enqueue(op: "upsert", entityType: .category, entity: c)
        let outbox = try context.fetch(FetchDescriptor<OutboxMutation>())
        #expect(outbox[0].payloadJSON.contains("\"gstFreeDefault\":true"))

        let id = ID.uuidv7()
        api.pullPages = [PullResponse(
            changes: [envelope(type: "category", id: id, rev: 1, updatedAt: 1000,
                               extra: ["profileId": "p1", "key": "meals", "label": "Meals",
                                       "icon": "tag", "tint": "#E8602C", "soft": "#FBEADF",
                                       "gstFreeDefault": false])],
            nextCursor: "C2", hasMore: false, serverTime: 1000)]
        await engine.pull()
        let row = try context.fetch(FetchDescriptor<Snapceipt.Category>(predicate: #Predicate { $0.id == id })).first!
        #expect(row.gstFreeDefault == false)
    }
}
