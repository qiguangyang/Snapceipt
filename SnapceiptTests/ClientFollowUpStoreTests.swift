import Testing
import Foundation
import SwiftData
@testable import Snapceipt

@MainActor @Suite("ClientFollowUpStore")
struct ClientFollowUpStoreTests {
    private func fixture() throws -> (ModelContext, MockSyncEngine, Client, ClientFollowUpStore) {
        let c = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        c.autosaveEnabled = false
        let client = Client(userId: "u1", profileId: "p1", name: "Client")
        c.insert(client); try c.save()
        let sync = MockSyncEngine()
        return (c, sync, client, ClientFollowUpStore(context: c, sync: sync, userId: "u1", profileId: "p1"))
    }
    @Test func validationAndCRUD() throws {
        let (_, sync, client, store) = try fixture()
        for (title, due, zone) in [(" \n", 200, "UTC"), (String(repeating: "a", count: 201), 200, "UTC"), ("Call", 100, "UTC"), ("Call", 200, "bad")] {
            #expect(throws: (any Error).self) { try store.save(id: nil, clientId: client.id, title: title, dueAt: due, timezone: zone, now: 100) }
        }
        #expect(sync.calls.isEmpty)
        let f = try store.save(id: nil, clientId: client.id, title: " Call \n", dueAt: 200, timezone: "UTC", now: 100)
        #expect(f.title == "Call")
        try store.complete(id: f.id, at: 300)
        #expect(try store.list(clientId: nil, includeCompleted: false).isEmpty)
        try store.reopen(id: f.id)
        #expect(try store.list(clientId: client.id, includeCompleted: false).first?.dueAt == 200)
        _ = try store.save(id: f.id, clientId: client.id, title: "Call later", dueAt: 500, timezone: "UTC", now: 400)
        try store.delete(id: f.id)
        #expect(try store.list(clientId: nil, includeCompleted: true).isEmpty)
        #expect(sync.calls.count == 5 && sync.calls.last?.op == "delete")
    }
    @Test func completionPreservesUnrelatedPendingFollowUpInput() throws {
        let (context, _, client, store) = try fixture()
        let f = try store.save(id: nil, clientId: client.id, title: "Saved", dueAt: 200, timezone: "UTC", now: 100)
        f.title = "Pending title"
        try store.complete(id: f.id, at: 300)
        #expect(f.title == "Pending title" && f.completedAt == 300)
        let saved = try ModelContext(context.container).fetch(FetchDescriptor<ClientFollowUp>()).first
        #expect(saved?.title == "Saved" && saved?.completedAt == 300)
    }
    @Test func requiresLiveClientInSameScope() throws {
        let (c, sync, _, store) = try fixture()
        for client in [Client(userId: "u2", profileId: "p1", name: "Foreign"), Client(userId: "u1", profileId: "p2", name: "Other"), Client(userId: "u1", profileId: "p1", name: "Deleted", deletedAt: 1)] {
            c.insert(client); try c.save()
            #expect(throws: (any Error).self) { try store.save(id: nil, clientId: client.id, title: "Call", dueAt: 200, timezone: "UTC", now: 100) }
        }
        #expect(sync.calls.isEmpty)
    }
    @Test func isolatedSavesPreservePendingInputAndFailureLeavesNoMutation() throws {
        let (c, sync, client, store) = try fixture()
        client.name = "Unsaved input"
        let f = try store.save(id: nil, clientId: client.id, title: "Call", dueAt: 200, timezone: "UTC", now: 100)
        let fresh = ModelContext(c.container)
        #expect(try fresh.fetch(FetchDescriptor<Client>()).first?.name == "Client")
        #expect(client.name == "Unsaved input")
        struct Failure: Error {}
        let failing = ClientFollowUpStore(context: c, sync: sync, userId: "u1", profileId: "p1", persist: { _ in throw Failure() })
        #expect(throws: Failure.self) { try failing.save(id: f.id, clientId: client.id, title: "Failed", dueAt: 300, timezone: "UTC", now: 100) }
        #expect(throws: Failure.self) { try failing.complete(id: f.id, at: 300) }
        #expect(throws: Failure.self) { try failing.delete(id: f.id) }
        #expect(throws: Failure.self) { try failing.save(id: nil, clientId: client.id, title: "Failed new", dueAt: 300, timezone: "UTC", now: 100) }
        #expect(sync.calls.count == 1)
        try c.save()
        let saved = try ModelContext(c.container).fetch(FetchDescriptor<ClientFollowUp>())
        #expect(saved.count == 1 && saved[0].title == "Call" && saved[0].completedAt == nil && saved[0].deletedAt == nil)
    }
}

@MainActor @Suite("ClientFollowUpAtomicStore")
struct ClientFollowUpAtomicStoreTests {
    @Test func failureDiscardsStagedOutboxAndKeepsOtherEditorInputUnsaved() throws {
        let context = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true)); context.autosaveEnabled = false
        let client = Client(userId: "u1", profileId: "p1", name: "Original")
        context.insert(client); try context.save(); client.name = "Pending input"
        let sync = SyncEngine(api: MockAPIClient(), context: context, auth: AuthStore(), toast: ToastCenter())
        struct Failure: Error {}
        let failing = ClientFollowUpStore(context: context, sync: sync, userId: "u1", profileId: "p1", persist: { _ in throw Failure() })
        #expect(throws: Failure.self) { try failing.save(id: nil, clientId: client.id, title: "Failed", dueAt: 200, timezone: "UTC", now: 100) }
        var fresh = ModelContext(context.container)
        #expect(try fresh.fetch(FetchDescriptor<ClientFollowUp>()).isEmpty)
        #expect(try fresh.fetch(FetchDescriptor<OutboxMutation>()).isEmpty)
        #expect(try fresh.fetch(FetchDescriptor<Client>()).first?.name == "Original")
        #expect(client.name == "Pending input")
        let store = ClientFollowUpStore(context: context, sync: sync, userId: "u1", profileId: "p1")
        _ = try store.save(id: nil, clientId: client.id, title: "Saved", dueAt: 200, timezone: "UTC", now: 100)
        fresh = ModelContext(context.container)
        #expect(try fresh.fetch(FetchDescriptor<ClientFollowUp>()).count == 1)
        #expect(try fresh.fetch(FetchDescriptor<OutboxMutation>()).count == 1)
        #expect(try fresh.fetch(FetchDescriptor<Client>()).first?.name == "Original")
    }
}
