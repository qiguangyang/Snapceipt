import Foundation
import SwiftData
import Testing
@testable import Snapceipt

@MainActor
@Suite(.serialized)
struct ClientWorkspaceSyncTests {
    private let versionKey = "sc.syncEntityVersion.workspace-test-user"

    private func makeEngine() throws -> (SyncEngine, ModelContext, MockAPIClient, AuthStore) {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        let context = ModelContext(container)
        let api = MockAPIClient()
        let auth = AuthStore(keychain: Keychain(service: "app.snapceipt.workspace-tests." + UUID().uuidString))
        auth.save(SessionResponse(accessToken: "test", refreshToken: "test", expiresIn: 900,
                                  user: SessionUser(id: "workspace-test-user", email: nil, displayName: nil)))
        UserDefaults.standard.removeObject(forKey: "sc.syncCursor")
        UserDefaults.standard.removeObject(forKey: versionKey)
        return (SyncEngine(api: api, context: context, auth: auth, toast: ToastCenter()), context, api, auth)
    }

    private func change(_ type: String, _ id: String, extra: [String: Any] = [:], updatedAt: Int = 1000) throws -> PullChange {
        var fields: [String: Any] = ["type": type, "id": id, "userId": "workspace-test-user", "profileId": "p1",
                                     "createdAt": 100, "updatedAt": updatedAt, "rev": 3,
                                     "deletedAt": NSNull(), "lastEditedDeviceId": "device"]
        fields.merge(extra) { _, new in new }
        return try JSONDecoder().decode(PullChange.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    @Test func clientWorkspacePayloadAndPullRoundTrip() async throws {
        let (engine, context, api, auth) = try makeEngine()
        defer { auth.clear(); UserDefaults.standard.removeObject(forKey: versionKey) }
        let client = Client(userId: "workspace-test-user", profileId: "p1", name: "A", notes: "Notes")
        let quote = Quote(userId: client.userId, profileId: "p1", clientId: client.id)
        let invoice = Invoice(userId: client.userId, profileId: "p1", clientId: client.id)
        let quoteLine = QuoteLineItem(userId: client.userId, quoteId: quote.id, itemDescription: "Work", unitLabel: "hour", unitPriceCents: 1200)
        let invoiceLine = InvoiceLineItem(userId: client.userId, invoiceId: invoice.id, itemDescription: "Work", unitLabel: "hour", unitPriceCents: 1200)
        let item = CatalogItem(userId: client.userId, profileId: "p1", itemDescription: "Service", unitLabel: "hour", unitPriceCents: 1250, currency: "USD")
        let followUp = ClientFollowUp(userId: client.userId, profileId: "p1", clientId: client.id, title: "Call", dueAt: 123456, timezone: "Australia/Sydney", completedAt: 123457)
        let registry = SyncEntityRegistry()
        let entities: [any Syncable] = [client, quote, invoice, quoteLine, invoiceLine, item, followUp]
        context.insert(client); context.insert(quote); context.insert(invoice)
        context.insert(quoteLine); context.insert(invoiceLine); context.insert(item); context.insert(followUp)
        try context.save()
        var changes: [PullChange] = []
        for entity in entities {
            let fields = registry.decodePayload(registry.encodePayload(entityType: entity.entityType, entity: entity))
            #expect(fields["id"]?.stringValue == entity.id)
            #expect(fields["userId"]?.stringValue == client.userId)
            if entity.entityType == .quote || entity.entityType == .invoice {
                #expect(fields["clientId"]?.stringValue == client.id)
                #expect(fields["pdfR2Key"] == nil)
            }
            if entity.entityType == .quoteLineItem || entity.entityType == .invoiceLineItem || entity.entityType == .catalogItem {
                #expect(fields["unitLabel"]?.stringValue == "hour")
            }
            if entity.entityType == .client { #expect(fields["notes"]?.stringValue == "Notes") }
            if entity.entityType == .catalogItem {
                #expect(fields["itemDescription"]?.stringValue == "Service")
                #expect(fields["unitPriceCents"]?.intValue == 1250)
                #expect(fields["currency"]?.stringValue == "USD")
            }
            if entity.entityType == .clientFollowUp {
                #expect(fields["clientId"]?.stringValue == client.id)
                #expect(fields["title"]?.stringValue == "Call")
                #expect(fields["dueAt"]?.intValue == 123456)
                #expect(fields["timezone"]?.stringValue == "Australia/Sydney")
                #expect(fields["completedAt"]?.intValue == 123457)
            }
            var pulled = fields
            pulled["updatedAt"] = .number(Double(entity.updatedAt + 1))
            pulled["rev"] = .number(4)
            let data = try JSONEncoder().encode(pulled)
            changes.append(try JSONDecoder().decode(PullChange.self, from: data))
        }
        // Round-trip into an empty store to prove every pushed field applies on pull.
        let destination = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        let pulledContext = ModelContext(destination)
        let pulledEngine = SyncEngine(api: api, context: pulledContext, auth: auth, toast: ToastCenter())
        api.pullPages = [PullResponse(changes: changes, nextCursor: "ROUNDTRIP", hasMore: false, serverTime: 1000)]
        await pulledEngine.pull()
        let pulledItem = try #require(pulledContext.fetch(FetchDescriptor<CatalogItem>()).first)
        let pulledFollowUp = try #require(pulledContext.fetch(FetchDescriptor<ClientFollowUp>()).first)
        #expect(pulledItem.itemDescription == "Service" && pulledItem.unitLabel == "hour" && pulledItem.unitPriceCents == 1250 && pulledItem.currency == "USD")
        #expect(pulledItem.userId == client.userId && pulledItem.profileId == "p1" && pulledItem.rev == 4)
        #expect(pulledItem.createdAt == item.createdAt && pulledItem.updatedAt == item.updatedAt + 1)
        #expect(pulledItem.deletedAt == nil && pulledItem.lastEditedDeviceId == item.lastEditedDeviceId)
        #expect(pulledFollowUp.clientId == client.id && pulledFollowUp.title == "Call" && pulledFollowUp.dueAt == 123456)
        #expect(pulledFollowUp.timezone == "Australia/Sydney" && pulledFollowUp.completedAt == 123457)
        #expect(pulledFollowUp.id == followUp.id && pulledFollowUp.userId == client.userId && pulledFollowUp.profileId == "p1")
        #expect(pulledFollowUp.rev == 4 && pulledFollowUp.createdAt == followUp.createdAt && pulledFollowUp.updatedAt == followUp.updatedAt + 1)
        #expect(try pulledContext.fetch(FetchDescriptor<Client>()).first?.notes == "Notes")
        #expect(try pulledContext.fetch(FetchDescriptor<Quote>()).first?.clientId == client.id)
        #expect(try pulledContext.fetch(FetchDescriptor<Invoice>()).first?.clientId == client.id)
        #expect(try pulledContext.fetch(FetchDescriptor<QuoteLineItem>()).first?.unitLabel == "hour")
        #expect(try pulledContext.fetch(FetchDescriptor<InvoiceLineItem>()).first?.unitLabel == "hour")
        let cleared: [(String, String, String)] = [("client", client.id, "notes"), ("quote", quote.id, "clientId"), ("invoice", invoice.id, "clientId"), ("quoteLineItem", quoteLine.id, "unitLabel"), ("invoiceLineItem", invoiceLine.id, "unitLabel"), ("catalogItem", item.id, "unitLabel"), ("clientFollowUp", followUp.id, "completedAt")]
        api.pullPages = [PullResponse(changes: try cleared.map { try change($0.0, $0.1, extra: [$0.2: NSNull(), "rev": 5], updatedAt: Epoch.nowMs() + 10000) }, nextCursor: "CLEARED", hasMore: false, serverTime: 2000)]
        await engine.pull()
        #expect(client.notes == nil && quote.clientId == nil && invoice.clientId == nil)
        #expect(quoteLine.unitLabel == nil && invoiceLine.unitLabel == nil && item.unitLabel == nil)
        #expect(followUp.completedAt == nil)
        for entity in entities {
            let payload = registry.decodePayload(registry.encodePayload(entityType: entity.entityType, entity: entity))
            let key = entity.entityType == .client ? "notes" : entity.entityType == .clientFollowUp ? "completedAt" : entity.entityType == .quote || entity.entityType == .invoice ? "clientId" : "unitLabel"
            if case .null? = payload[key] {} else { Issue.record("Expected explicit null for \(key)") }
        }
    }

    @Test func legacyPullDefaults() async throws {
        let (engine, context, api, auth) = try makeEngine()
        defer { auth.clear(); UserDefaults.standard.removeObject(forKey: versionKey) }
        api.pullPages = [PullResponse(changes: try ["client", "quote", "invoice", "quoteLineItem", "invoiceLineItem"].map { try change($0, ID.uuidv7()) }, nextCursor: "LEGACY", hasMore: false, serverTime: 1000)]
        await engine.pull()
        #expect(try context.fetch(FetchDescriptor<Client>()).first?.notes == nil)
        #expect(try context.fetch(FetchDescriptor<Quote>()).first?.clientId == nil)
        #expect(try context.fetch(FetchDescriptor<Invoice>()).first?.clientId == nil)
        #expect(try context.fetch(FetchDescriptor<QuoteLineItem>()).first?.unitLabel == nil)
        #expect(try context.fetch(FetchDescriptor<InvoiceLineItem>()).first?.unitLabel == nil)
    }

    @Test func omittedAdditiveFieldsPreserveExistingValues() throws {
        let (_, context, _, auth) = try makeEngine()
        defer { auth.clear() }
        let client = Client(userId: "workspace-test-user", profileId: "p1", name: "A", notes: "Retain notes")
        let quote = Quote(userId: client.userId, profileId: "p1", clientId: client.id)
        let invoice = Invoice(userId: client.userId, profileId: "p1", clientId: client.id)
        let quoteLine = QuoteLineItem(userId: client.userId, quoteId: quote.id, itemDescription: "Work", unitLabel: "hour", unitPriceCents: 100)
        let invoiceLine = InvoiceLineItem(userId: client.userId, invoiceId: invoice.id, itemDescription: "Work", unitLabel: "hour", unitPriceCents: 100)
        context.insert(client); context.insert(quote); context.insert(invoice)
        context.insert(quoteLine); context.insert(invoiceLine)
        let registry = SyncEntityRegistry()
        for row: any Syncable in [client, quote, invoice, quoteLine, invoiceLine] {
            registry.handler(for: row.entityType)?.applyPulled(context, try change(row.entityType.rawValue, row.id))
        }
        try context.save()
        #expect(client.notes == "Retain notes" && quote.clientId == client.id && invoice.clientId == client.id)
        #expect(quoteLine.unitLabel == "hour" && invoiceLine.unitLabel == "hour")
    }

    @Test func allV2TypesRegistered() {
        #expect(EntityType.allCases.count == 20)
        #expect(SnapceiptSchema.models.count == 22)
        let registry = SyncEntityRegistry()
        for type in EntityType.allCases { #expect(registry.handler(for: type) != nil) }
        #expect(EntityType.catalogItem.rawValue == "catalogItem")
        #expect(EntityType.clientFollowUp.rawValue == "clientFollowUp")
    }

    @Test func localWipeIncludesV2Rows() throws {
        let (_, context, _, auth) = try makeEngine()
        defer { auth.clear() }
        context.insert(CatalogItem(userId: "u1", profileId: "p1"))
        context.insert(ClientFollowUp(userId: "u1", profileId: "p1"))
        try context.save()
        LocalStore.wipe(context: context)
        #expect(try context.fetch(FetchDescriptor<CatalogItem>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<ClientFollowUp>()).isEmpty)
    }

    @Test func registryUpgradeFullPullPreservesOutbox() async throws {
        let (engine, context, api, auth) = try makeEngine()
        defer { auth.clear(); UserDefaults.standard.removeObject(forKey: versionKey) }
        UserDefaults.standard.set("V1-CURSOR", forKey: "sc.syncCursor")
        UserDefaults.standard.set(18, forKey: versionKey)
        let quote = Quote(userId: "workspace-test-user", profileId: "p1", clientName: "Pending edit", updatedAt: 1000)
        context.insert(quote); engine.enqueue(op: "upsert", entityType: .quote, entity: quote)
        let payload = try #require(context.fetch(FetchDescriptor<OutboxMutation>()).first).payloadJSON
        api.pullPages = [PullResponse(changes: [try change("catalogItem", ID.uuidv7(), extra: ["itemDescription": "Old service"], updatedAt: 100), try change("quote", quote.id, extra: ["clientName": "Server edit"], updatedAt: 2000)], nextCursor: "PAGE1", hasMore: true, serverTime: 2000), PullResponse(changes: [try change("clientFollowUp", ID.uuidv7(), extra: ["clientId": "c1", "title": "Old reminder"], updatedAt: 100)], nextCursor: "COMPLETE", hasMore: false, serverTime: 2000)]
        await engine.pull()
        #expect(api.pullCursors.count == 2 && api.pullCursors[0] == nil && api.pullCursors[1] == "PAGE1")
        #expect(quote.clientName == "Pending edit")
        let outbox = try context.fetch(FetchDescriptor<OutboxMutation>())
        #expect(outbox.count == 1 && outbox[0].payloadJSON == payload && outbox[0].status == "pending")
        #expect(try context.fetch(FetchDescriptor<CatalogItem>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<ClientFollowUp>()).count == 1)
        #expect(UserDefaults.standard.integer(forKey: versionKey) == 20)
        await engine.pull()
        #expect(api.pullCursors.last! == "COMPLETE")
    }

    @Test(arguments: [1, 2]) func failedUpgradePullRetries(failedPage: Int) async throws {
        let (engine, context, api, auth) = try makeEngine()
        defer { auth.clear(); UserDefaults.standard.removeObject(forKey: versionKey) }
        UserDefaults.standard.set("V1-CURSOR", forKey: "sc.syncCursor")
        let id = ID.uuidv7()
        var calls = 0
        api.pullHandler = { _, _ in
            calls += 1
            if calls == failedPage { throw MockAPIClientError.unscripted }
            let partial = failedPage == 2 && calls == 1
            return PullResponse(changes: [try self.change("catalogItem", id, extra: ["itemDescription": "Retried service"], updatedAt: 100)], nextCursor: partial ? "PARTIAL" : "COMPLETE", hasMore: partial, serverTime: 1000)
        }
        await engine.pull()
        #expect(engine.status == .offline)
        #expect(UserDefaults.standard.integer(forKey: versionKey) != 20)
        await engine.pull()
        #expect(api.pullCursors.count == failedPage + 1)
        #expect(api.pullCursors[0] == nil && api.pullCursors[failedPage] == nil)
        if failedPage == 2 { #expect(api.pullCursors[1] == "PARTIAL") }
        #expect(try context.fetch(FetchDescriptor<CatalogItem>()).count == 1)
        #expect(UserDefaults.standard.integer(forKey: versionKey) == 20)
    }
}
