import Foundation
import SwiftData
import Testing
@testable import Snapceipt

@MainActor
private func makeEngine() throws -> (SyncEngine, ModelContext, MockAPIClient, AuthStore, ToastCenter) {
    let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
    let context = ModelContext(container)
    let api = MockAPIClient()
    let auth = AuthStore()
    let toast = ToastCenter()
    let engine = SyncEngine(api: api, context: context, auth: auth, toast: toast)
    UserDefaults.standard.removeObject(forKey: "sc.syncCursor")
    return (engine, context, api, auth, toast)
}

/// Build a server entity envelope through PullChange's real Decodable path
/// (it has a custom init(from:), so there is no memberwise initializer).
private func envelope(
    type: String, id: String, userId: String = "u1",
    rev: Int, updatedAt: Int, createdAt: Int? = nil, deletedAt: Int? = nil,
    extra: [String: Any] = [:]
) -> PullChange {
    var fields: [String: Any] = [
        "type": type, "id": id, "userId": userId, "rev": rev,
        "createdAt": createdAt ?? updatedAt, "updatedAt": updatedAt,
        "lastEditedDeviceId": NSNull(),
    ]
    if let deletedAt { fields["deletedAt"] = deletedAt } else { fields["deletedAt"] = NSNull() }
    for (k, v) in extra { fields[k] = v }
    let data = try! JSONSerialization.data(withJSONObject: fields)
    return try! JSONDecoder().decode(PullChange.self, from: data)
}

@MainActor
@Suite(.serialized)
struct LogbookSyncTests {

    @Test func enqueueVehicleEncodesAllFields() throws {
        let (engine, context, _, _, _) = try makeEngine()
        let v = Vehicle(userId: "u1", profileId: "p1", make: "Toyota",
                        model: "HiLux", engineCc: 2800, registration: "ABC123",
                        logbookStartDate: "2025-08-12", logbookEndDate: "2025-11-04",
                        businessUsePct: 78)
        context.insert(v)
        engine.enqueue(op: "upsert", entityType: .vehicle, entity: v)

        let outbox = try context.fetch(FetchDescriptor<OutboxMutation>())
        #expect(outbox.count == 1)
        #expect(outbox[0].entityType == EntityType.vehicle.rawValue)
        #expect(outbox[0].payloadJSON.contains("HiLux"))
        #expect(outbox[0].payloadJSON.contains("logbookStartDate"))
        #expect(outbox[0].payloadJSON.contains("businessUsePct"))
    }

    @Test func pullUpsertsVehicle() async throws {
        let (engine, context, api, _, _) = try makeEngine()
        let id = ID.uuidv7()
        api.pullPages = [
            PullResponse(
                changes: [envelope(type: "vehicle", id: id, rev: 3, updatedAt: 7000,
                                   extra: ["profileId": "p1", "make": "Toyota", "model": "HiLux",
                                           "engineCc": 2800, "registration": "ABC123",
                                           "logbookStartDate": "2025-08-12",
                                           "logbookEndDate": "2025-11-04", "businessUsePct": 78])],
                nextCursor: "C1", hasMore: false, serverTime: 7000)
        ]
        await engine.pull()

        let rows = try context.fetch(FetchDescriptor<Vehicle>(predicate: #Predicate { $0.id == id }))
        #expect(rows.count == 1)
        #expect(rows[0].make == "Toyota")
        #expect(rows[0].businessUsePct == 78)
        #expect(rows[0].rev == 3)
    }

    @Test func pullUpsertsVehicleYear() async throws {
        let (engine, context, api, _, _) = try makeEngine()
        let id = ID.uuidv7()
        api.pullPages = [
            PullResponse(
                changes: [envelope(type: "vehicleYear", id: id, rev: 1, updatedAt: 5000,
                                   extra: ["profileId": "p1", "vehicleId": "veh-1",
                                           "fyStartYear": 2025, "fuelCents": 200_000,
                                           "businessUsePct": 78, "claimCents": 321_360])],
                nextCursor: "C2", hasMore: false, serverTime: 5000)
        ]
        await engine.pull()

        let rows = try context.fetch(FetchDescriptor<VehicleYear>(predicate: #Predicate { $0.id == id }))
        #expect(rows.count == 1)
        #expect(rows[0].vehicleId == "veh-1")
        #expect(rows[0].fyStartYear == 2025)
        #expect(rows[0].fuelCents == 200_000)
        #expect(rows[0].claimCents == 321_360)
    }

    @Test func mileageTripPayloadAndPullCarryNewFields() async throws {
        let (engine, context, api, _, _) = try makeEngine()
        // enqueue carries the new fields:
        let t = MileageTrip(userId: "u1", profileId: "p1", tripDate: "2025-09-01",
                            distanceM: 12_400, isBusiness: true, vehicleId: "veh-1",
                            odometerStartM: 10_000_000, odometerEndM: 10_012_400)
        context.insert(t)
        engine.enqueue(op: "upsert", entityType: .mileageTrip, entity: t)
        let outbox = try context.fetch(FetchDescriptor<OutboxMutation>())
        #expect(outbox[0].payloadJSON.contains("odometerStartM"))
        #expect(outbox[0].payloadJSON.contains("veh-1"))

        // pull applies the new fields:
        let id = ID.uuidv7()
        api.pullPages = [
            PullResponse(
                changes: [envelope(type: "mileageTrip", id: id, rev: 1, updatedAt: 6000,
                                   extra: ["profileId": "p1", "tripDate": "2025-09-02",
                                           "distanceM": 8000, "isBusiness": false,
                                           "vehicleId": "veh-9", "odometerStartM": 1000,
                                           "odometerEndM": 9000])],
                nextCursor: "C3", hasMore: false, serverTime: 6000)
        ]
        await engine.pull()
        let rows = try context.fetch(FetchDescriptor<MileageTrip>(predicate: #Predicate { $0.id == id }))
        #expect(rows.count == 1)
        #expect(rows[0].vehicleId == "veh-9")
        #expect(rows[0].odometerStartM == 1000)
        #expect(rows[0].odometerEndM == 9000)
    }
}
