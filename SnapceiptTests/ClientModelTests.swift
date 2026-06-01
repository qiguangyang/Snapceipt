import Testing
import Foundation
import SwiftData
@testable import Snapceipt

@MainActor
@Suite("Client model")
struct ClientModelTests {
    @Test("Client defaults: entityType is .client, profileId/email start as passed-in")
    func defaults() throws {
        let c = Client(userId: "u1", profileId: "p1", name: "Acme Pty Ltd", email: "ap@acme.com")
        #expect(c.entityType == .client)
        #expect(c.userId == "u1")
        #expect(c.profileId == "p1")
        #expect(c.name == "Acme Pty Ltd")
        #expect(c.email == "ap@acme.com")
        #expect(c.deletedAt == nil)
        #expect(c.rev == 0)
    }

    @Test("Client persists + round-trips through a SwiftData context scoped by profileId")
    func persists() throws {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        let ctx = ModelContext(container)
        ctx.insert(Client(userId: "u1", profileId: "p1", name: "A", email: nil))
        ctx.insert(Client(userId: "u1", profileId: "p2", name: "B", email: "b@x.com"))
        try ctx.save()
        let pid = "p1"
        let rows = try ctx.fetch(FetchDescriptor<Client>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil }))
        #expect(rows.count == 1)
        #expect(rows[0].name == "A")
        #expect(rows[0].email == nil)
    }

    @Test("EntityType has a .client case with the camelCase raw value 'client'")
    func entityTypeCase() {
        #expect(EntityType.client.rawValue == "client")
        #expect(EntityType.allCases.contains(.client))
    }

    @Test("ClientSyncMapper payload round-trips name/email + the shared envelope")
    func mapperRoundTrip() throws {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        let ctx = ModelContext(container)
        let registry = SyncEntityRegistry()
        let src = Client(userId: "u1", profileId: "p1", name: "Acme", email: "ap@acme.com")
        src.rev = 3
        ctx.insert(src)
        try ctx.save()

        let json = registry.encodePayload(entityType: .client, entity: src)
        let fields = registry.decodePayload(json)
        #expect(fields["name"]?.stringValue == "Acme")
        #expect(fields["email"]?.stringValue == "ap@acme.com")
        #expect(fields["id"]?.stringValue == src.id)
        #expect(fields["profileId"]?.stringValue == "p1")
        #expect(fields["rev"]?.intValue == 3)
    }

    @Test("ClientSyncMapper upserts a pulled envelope into a Client row")
    func mapperUpsert() throws {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        let ctx = ModelContext(container)
        let registry = SyncEntityRegistry()
        let envJSON = """
        {"type":"client","id":"c-1","userId":"u1","profileId":"p1",
         "name":"Beta Co","email":"beta@co.com",
         "createdAt":1,"updatedAt":2,"deletedAt":null,"rev":5,"lastEditedDeviceId":null}
        """
        let env = try JSONDecoder().decode(PullChange.self, from: Data(envJSON.utf8))
        registry.handler(for: .client)?.applyPulled(ctx, env)
        try ctx.save()
        let rows = try ctx.fetch(FetchDescriptor<Client>())
        #expect(rows.count == 1)
        #expect(rows[0].id == "c-1")
        #expect(rows[0].name == "Beta Co")
        #expect(rows[0].email == "beta@co.com")
        #expect(rows[0].rev == 5)
    }
}
