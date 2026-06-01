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
}
