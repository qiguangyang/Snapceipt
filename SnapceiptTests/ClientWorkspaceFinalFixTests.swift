import Foundation
import SwiftData
import Testing
@testable import Snapceipt

@MainActor @Suite(.serialized)
struct ClientWorkspaceFinalFixTests {
    @MainActor private final class SignalCount { var value = 0 }

    private func fixture() throws -> (ModelContext, SyncEngine, MockAPIClient) {
        let context = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        context.autosaveEnabled = false
        let api = MockAPIClient()
        return (context, SyncEngine(api: api, context: context, auth: AuthStore(), toast: ToastCenter()), api)
    }

    @Test func clientCrudCommitsStagedOutboxAtomicallyAndPreservesInput() throws {
        let (context, engine, _) = try fixture()
        let other = Client(userId: "u", profileId: "p", name: "Other", notes: "Saved")
        context.insert(other); try context.save()
        other.notes = "Pending unrelated input"
        let signals = SignalCount()
        let observer = NotificationCenter.default.addObserver(forName: .clientFollowUpsDidChange, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { signals.value += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        enum Failure: Error { case save }
        var fail = true
        var stagedCounts: [Int] = []
        let store = ClientStore(context: context, sync: engine, userId: "u", profileId: "p", persist: { transaction in
            stagedCounts.append(try transaction.fetch(FetchDescriptor<OutboxMutation>()).count)
            if fail { throw Failure.save }
            try transaction.save()
        })
        let editor = ClientEditViewModel(store: store)
        editor.draft = ClientDraft(name: "New", notes: "Typed notes")
        var succeeded = false
        #expect(!editor.save(onSaved: { _ in succeeded = true }))
        #expect(!succeeded && editor.errorMessage != nil && editor.draft.notes == "Typed notes")
        #expect(stagedCounts == [1])
        #expect(try ModelContext(context.container).fetch(FetchDescriptor<OutboxMutation>()).isEmpty)
        #expect(try ModelContext(context.container).fetch(FetchDescriptor<Client>()).count == 1)
        fail = false
        let client = try store.save(id: nil, draft: editor.draft)
        let original = try #require(ModelContext(context.container).fetch(FetchDescriptor<OutboxMutation>()).first)
        let originalId = original.mutationId, originalTime = original.createdAt
        // Commit setup independently so the unrelated shared edit remains dirty.
        let setup = ModelContext(context.container)
        let follow1 = ClientFollowUp(userId: "u", profileId: "p", clientId: client.id, title: "First")
        let follow2 = ClientFollowUp(userId: "u", profileId: "p", clientId: client.id, title: "Second", completedAt: 50)
        setup.insert(follow1); setup.insert(follow2); try setup.save()
        let loaded = try context.fetch(FetchDescriptor<ClientFollowUp>())
        loaded[0].title = "Pending follow-up input"
        client.notes = "Pending client input"
        fail = true
        #expect(throws: Failure.self) { try store.save(id: client.id, draft: ClientDraft(name: "Edited")) }
        #expect(throws: Failure.self) { try store.delete(id: client.id) }
        #expect(stagedCounts.suffix(2) == [1, 4])
        #expect(signals.value == 0)
        var reader = ModelContext(context.container)
        #expect(try reader.fetch(FetchDescriptor<Client>()).first { $0.id == client.id }?.name == "New")
        #expect(try reader.fetch(FetchDescriptor<ClientFollowUp>()).allSatisfy { $0.deletedAt == nil })
        #expect(try reader.fetch(FetchDescriptor<OutboxMutation>()).count == 1)
        #expect(client.notes == "Pending client input" && loaded[0].title == "Pending follow-up input")
        fail = false
        _ = try store.save(id: client.id, draft: ClientDraft(name: "Edited", notes: "Latest"))
        reader = ModelContext(context.container)
        let updated = try #require(reader.fetch(FetchDescriptor<OutboxMutation>()).first)
        #expect(updated.mutationId == originalId && updated.createdAt == originalTime && updated.baseRev == 0)
        #expect(updated.payloadJSON.contains("Latest"))
        try store.delete(id: client.id)
        reader = ModelContext(context.container)
        #expect(try reader.fetch(FetchDescriptor<OutboxMutation>()).filter { $0.op == "delete" }.count == 3)
        #expect(try reader.fetch(FetchDescriptor<ClientFollowUp>()).allSatisfy { $0.deletedAt != nil })
        #expect(signals.value == 1)
        #expect(client.deletedAt != nil && loaded.allSatisfy { $0.deletedAt != nil })
        #expect(loaded[0].title == "Pending follow-up input")
        #expect(other.notes == "Pending unrelated input")
        #expect(try reader.fetch(FetchDescriptor<Client>()).first { $0.id == other.id }?.notes == "Saved")
    }

    @Test func dedupedParentsStayBeforeChildrenAcrossPushBatchBoundary() async throws {
        let (context, engine, api) = try fixture()
        // 199 independent entries put the client at the end of the first batch.
        for index in 0..<199 {
            let item = CatalogItem(userId: "u", profileId: "p", itemDescription: "Item \(index)")
            context.insert(item); engine.enqueue(op: "upsert", entityType: .catalogItem, entity: item)
        }
        let client = Client(userId: "u", profileId: "p", name: "Before")
        let quote = Quote(userId: "u", profileId: "p", clientId: client.id)
        let invoice = Invoice(userId: "u", profileId: "p", clientId: client.id)
        let follow = ClientFollowUp(userId: "u", profileId: "p", clientId: client.id, title: "Call")
        let qline = QuoteLineItem(userId: "u", quoteId: quote.id, itemDescription: "Work", unitPriceCents: 100)
        let iline = InvoiceLineItem(userId: "u", invoiceId: invoice.id, itemDescription: "Work", unitPriceCents: 100)
        context.insert(client); context.insert(quote); context.insert(invoice)
        context.insert(follow); context.insert(qline); context.insert(iline)
        for row: any Syncable in [client, quote, invoice, follow, qline, iline] {
            engine.enqueue(op: "upsert", entityType: row.entityType, entity: row)
        }
        client.name = "Latest"; client.rev = 7
        quote.clientName = "Latest"; invoice.clientName = "Latest"
        for row: any Syncable in [client, quote, invoice] { engine.enqueue(op: "upsert", entityType: row.entityType, entity: row) }
        var seen: Set<String> = []
        let dependencies = [quote.id: client.id, invoice.id: client.id, follow.id: client.id, qline.id: quote.id, iline.id: invoice.id]
        api.pushHandler = { batch in
            let results = batch.map { mutation in
                let valid = dependencies[mutation.entityId].map { seen.contains($0) } ?? true
                #expect(valid, "Parent must already exist for \(mutation.entityType)")
                if valid { seen.insert(mutation.entityId) }
                return PushResult(mutationId: mutation.mutationId, status: valid ? "applied" : "rejected", reason: nil, entity: nil)
            }
            return PushResponse(results: results, serverTime: 1000)
        }
        await engine.push()
        #expect(api.pushCalls.map(\.count) == [200, 5])
        #expect(api.pushCalls.first?.last?.entityId == client.id)
        let sent = try #require(api.pushCalls.flatMap { $0 }.first { $0.entityId == client.id })
        #expect(sent.baseRev == 0)
        let payload = try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(sent.payload))
        #expect(payload["name"]?.stringValue == "Latest")
        #expect(try ModelContext(context.container).fetch(FetchDescriptor<OutboxMutation>()).isEmpty)
    }

    @Test func contactNullClearsOmissionRetainsAndRepeatUsesCurrentContact() async throws {
        let (context, engine, api) = try fixture()
        let client = Client(userId: "u", profileId: "p", name: "Current", email: "old@test", mobilePhone: "123", address: "Old address")
        let quote = Quote(userId: "u", profileId: "p", clientId: client.id, clientEmail: "historical@test", clientAddress: "History", clientMobile: "456")
        let invoice = Invoice(userId: "u", profileId: "p", clientId: client.id, clientEmail: "historical@test")
        context.insert(client); context.insert(quote); context.insert(invoice)
        context.insert(QuoteLineItem(userId: "u", quoteId: quote.id, itemDescription: "Work", unitPriceCents: 100))
        context.insert(InvoiceLineItem(userId: "u", invoiceId: invoice.id, itemDescription: "Work", unitPriceCents: 100)); try context.save()
        func pull(_ extras: [String: Any], rev: Int) async throws {
            var fields: [String: Any] = ["type": "client", "id": client.id, "userId": "u", "profileId": "p", "createdAt": 100, "updatedAt": Epoch.nowMs() + rev, "rev": rev]
            fields.merge(extras) { _, new in new }
            let change = try JSONDecoder().decode(PullChange.self, from: JSONSerialization.data(withJSONObject: fields))
            api.pullPages = [PullResponse(changes: [change], nextCursor: "contact-\(rev)", hasMore: false, serverTime: 1000)]
            await engine.pull()
        }
        try await pull(["name": "Renamed"], rev: 2)
        #expect(client.email == "old@test" && client.mobilePhone == "123" && client.address == "Old address")
        try await pull(["email": NSNull(), "mobilePhone": NSNull(), "address": NSNull()], rev: 3)
        #expect(client.email == nil && client.mobilePhone == nil && client.address == nil)
        let repeatWork = RepeatWorkService(context: context, sync: engine, userId: "u", profileId: "p")
        let qid = try repeatWork.repeatQuote(sourceId: quote.id, now: Date())
        let iid = try repeatWork.repeatInvoice(sourceId: invoice.id, now: Date())
        let reader = ModelContext(context.container)
        let repeatedQ = try #require(reader.fetch(FetchDescriptor<Quote>()).first { $0.id == qid })
        let repeatedI = try #require(reader.fetch(FetchDescriptor<Invoice>()).first { $0.id == iid })
        #expect(repeatedQ.clientEmail == nil && repeatedQ.clientAddress == nil && repeatedQ.clientMobile == nil)
        #expect(repeatedI.clientEmail == nil)
        #expect(quote.clientEmail == "historical@test" && quote.clientAddress == "History" && quote.clientMobile == "456")
        #expect(invoice.clientEmail == "historical@test")
    }

    @Test(arguments: ["🛠", "e\u{301}"])
    func textLimitsUseExactUTF16Boundaries(unit: String) throws {
        let (context, engine, _) = try fixture()
        let store = ClientStore(context: context, sync: engine, userId: "u", profileId: "p")
        let name = String(repeating: unit, count: 100), notes = String(repeating: unit, count: 5000)
        #expect(name.utf16.count == 200 && notes.utf16.count == 10_000)
        let client = try store.save(id: nil, draft: ClientDraft(name: name, notes: notes))
        let followStore = ClientFollowUpStore(context: context, sync: engine, userId: "u", profileId: "p")
        _ = try followStore.save(id: nil, clientId: client.id, title: name, dueAt: 200, timezone: "UTC", now: 100)
        let signals = SignalCount()
        let observer = NotificationCenter.default.addObserver(forName: .clientFollowUpsDidChange, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { signals.value += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let before = try ModelContext(context.container).fetch(FetchDescriptor<OutboxMutation>()).map(\.payloadJSON).sorted()
        #expect(throws: ClientStore.ValidationError.self) { try store.save(id: client.id, draft: ClientDraft(name: name + "a")) }
        #expect(throws: ClientStore.ValidationError.self) { try store.save(id: client.id, draft: ClientDraft(name: "Name", notes: notes + "a")) }
        #expect(throws: ClientFollowUpStore.ValidationError.self) { try followStore.save(id: nil, clientId: client.id, title: name + "a", dueAt: 200, timezone: "UTC", now: 100) }
        let reader = ModelContext(context.container)
        #expect(try reader.fetch(FetchDescriptor<OutboxMutation>()).map(\.payloadJSON).sorted() == before)
        #expect(try reader.fetch(FetchDescriptor<ClientFollowUp>()).count == 1)
        #expect(signals.value == 0)
    }

    @Test func catalogRejectsMismatchedCurrencyInNewAndRepeatedDocuments() throws {
        let (context, engine, _) = try fixture()
        let pid = "currency-" + UUID().uuidString
        defer { UserDefaults.standard.removeObject(forKey: AppSettings.businessCurrencyKey(pid)) }
        AppSettings.setBusinessCurrency("AUD", profileId: pid)
        let catalog = CatalogStore(context: context, sync: engine, userId: "u", profileId: pid)
        let aud = try catalog.save(id: nil, description: "AUD work", unitLabel: nil, unitPriceCents: 10000)
        let client = Client(userId: "u", profileId: pid, name: "Client")
        let quote = Quote(userId: "u", profileId: pid, clientId: client.id, currency: "AUD")
        let invoice = Invoice(userId: "u", profileId: pid, clientId: client.id, currency: "AUD")
        context.insert(client); context.insert(quote); context.insert(invoice)
        context.insert(QuoteLineItem(userId: "u", quoteId: quote.id, itemDescription: "Work", unitPriceCents: 100))
        context.insert(InvoiceLineItem(userId: "u", invoiceId: invoice.id, itemDescription: "Work", unitPriceCents: 100)); try context.save()
        AppSettings.setBusinessCurrency("NZD", profileId: pid)
        let nzd = try catalog.save(id: nil, description: "NZD work", unitLabel: nil, unitPriceCents: 20000)
        let service = RepeatWorkService(context: context, sync: engine, userId: "u", profileId: pid)
        let repeatedQ = try service.repeatQuote(sourceId: quote.id, now: Date())
        let repeatedI = try service.repeatInvoice(sourceId: invoice.id, now: Date())
        for repeated in [false, true] {
            let q = QuoteEditorViewModel(context: context, sync: engine, userId: "u", profileId: pid)
            let i = InvoiceEditorViewModel(context: context, sync: engine, userId: "u", profileId: pid)
            q.load(id: repeated ? repeatedQ : nil); i.load(id: repeated ? repeatedI : nil)
            let bad = repeated ? nzd : aud, good = repeated ? aud : nzd
            let counts = (q.lineItems.count, i.lineItems.count)
            for insert in [{ try q.addCatalogItem(bad) }, { try i.addCatalogItem(bad) }] {
                do { _ = try insert(); Issue.record("Currency mismatch must be rejected") }
                catch { #expect(error.localizedDescription.contains("AUD") && error.localizedDescription.contains("NZD")) }
            }
            #expect(q.lineItems.count == counts.0 && i.lineItems.count == counts.1)
            try q.addCatalogItem(good); try i.addCatalogItem(good)
            #expect(q.saveDraft() && i.saveDraft())
        }
        #expect(quote.currency == "AUD" && invoice.currency == "AUD" && aud.currency == "AUD" && nzd.currency == "NZD")
    }

    @Test(arguments: [false, true], [0, 199])
    func earlierPendingDocumentAcquiresLaterClient(invoice: Bool, padding: Int) async throws {
        let (context, engine, api) = try fixture()
        for index in 0..<padding {
            let item = CatalogItem(userId: "u", profileId: "p", itemDescription: "Unrelated \(index)")
            context.insert(item)
            engine.enqueue(op: "upsert", entityType: .catalogItem, entity: item)
        }
        let document: any Syncable
        let line: any Syncable
        if invoice {
            let row = Invoice(userId: "u", profileId: "p", clientName: "Edited invoice", rev: 7)
            let child = InvoiceLineItem(userId: "u", invoiceId: row.id, itemDescription: "Edited line", unitPriceCents: 125)
            context.insert(row); context.insert(child)
            document = row; line = child
        } else {
            let row = Quote(userId: "u", profileId: "p", clientName: "Edited quote", rev: 7)
            let child = QuoteLineItem(userId: "u", quoteId: row.id, itemDescription: "Edited line", unitPriceCents: 125)
            context.insert(row); context.insert(child)
            document = row; line = child
        }
        try context.save()
        engine.enqueue(op: "upsert", entityType: document.entityType, entity: document)
        engine.enqueue(op: "upsert", entityType: line.entityType, entity: line)
        let initial = try #require(context.fetch(FetchDescriptor<OutboxMutation>()).first { $0.entityId == document.id })
        let mutationId = initial.mutationId, enqueueTime = initial.createdAt
        let store = ClientStore(context: context, sync: engine, userId: "u", profileId: "p")
        let client = try store.save(id: nil, draft: ClientDraft(name: "Later client"))
        try store.linkExistingDocuments(clientId: client.id, documents: [.init(kind: invoice ? .invoice : .quote, id: document.id)])
        let before = try ModelContext(context.container).fetch(FetchDescriptor<OutboxMutation>())
        let linked = try #require(before.first { $0.entityId == document.id })
        #expect(linked.mutationId == mutationId && linked.createdAt == enqueueTime && linked.baseRev == 7)
        #expect(SyncEntityRegistry().decodePayload(linked.payloadJSON)["clientId"]?.stringValue == client.id)
        var serverClients: Set<String> = []
        // Existing server document has no client until the association upsert applies.
        var serverDocumentClient: String?
        var appliedLines: Set<String> = []
        api.pushHandler = { batch in
            let results = try batch.map { mutation in
                let fields = try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(mutation.payload))
                var valid = true
                if mutation.entityType == "client" { serverClients.insert(mutation.entityId) }
                if mutation.entityId == document.id {
                    let ref = fields["clientId"]?.stringValue
                    valid = ref.map { serverClients.contains($0) } ?? true
                    if valid { serverDocumentClient = ref }
                    #expect(mutation.baseRev == 7 && fields["clientName"]?.stringValue == (invoice ? "Edited invoice" : "Edited quote"))
                }
                if mutation.entityId == line.id {
                    #expect(serverDocumentClient == client.id, "The updated parent must precede its line")
                    if serverDocumentClient == client.id { appliedLines.insert(mutation.entityId) }
                }
                #expect(valid, "New client must exist before the association upsert")
                return PushResult(mutationId: mutation.mutationId, status: valid ? "applied" : "rejected", reason: valid ? nil : "VALIDATION_FAILED", entity: nil)
            }
            return PushResponse(results: results, serverTime: 1000)
        }
        await engine.push()
        let sent = api.pushCalls.flatMap { $0 }
        #expect(sent.count == before.count && Set(sent.map(\.mutationId)) == Set(before.map(\.mutationId)))
        #expect(Array(sent.suffix(3).map(\.entityId)) == [client.id, document.id, line.id])
        #expect(api.pushCalls.map(\.count) == (padding == 199 ? [200, 2] : [3]))
        #expect(serverDocumentClient == client.id && appliedLines == [line.id])
        #expect(try ModelContext(context.container).fetch(FetchDescriptor<OutboxMutation>()).isEmpty)
    }

    @Test func absentNullUnknownAndDeleteReferencesKeepQueueOrderAndServerValidation() async throws {
        let (context, engine, api) = try fixture()
        // Only a typed reference to an actual pending upsert creates an ordering edge.
        // Missing parent, malformed value, delete-only parent and unknown fields are
        // still sent unchanged for the server to accept/reject under its contract.
        let fixtures: [(type: String, id: String, op: String, payload: String)] = [
            ("quote", "omitted", "upsert", "{}"),
            ("invoice", "null", "upsert", "{\"clientId\":null}"),
            ("quote", "missing", "upsert", "{\"clientId\":\"not-pending\"}"),
            ("invoice", "number", "upsert", "{\"clientId\":12}"),
            ("clientFollowUp", "deleted-parent", "upsert", "{\"clientId\":\"deleted\"}"),
            ("client", "deleted", "delete", "{}"),
            ("quote", "delete", "delete", "{\"clientId\":\"later\"}"),
            ("catalogItem", "not-a-reference", "upsert", "{\"clientId\":\"later\"}"),
            // Cross-type back references cannot manufacture a graph cycle.
            ("client", "later", "upsert", "{\"clientId\":\"omitted\",\"quoteId\":\"omitted\"}")
        ]
        for (index, fixture) in fixtures.enumerated() {
            context.insert(OutboxMutation(entityType: fixture.type, entityId: fixture.id,
                op: fixture.op, payloadJSON: fixture.payload, createdAt: index + 1))
        }
        // A failed parent is not pending and must not be pulled into this push.
        let failed = OutboxMutation(entityType: "client", entityId: "not-pending", op: "upsert", payloadJSON: "{}", createdAt: 0, status: "failed")
        context.insert(failed); try context.save()
        api.pushHandler = { batch in
            PushResponse(results: batch.map { mutation in
                let rejected = ["missing", "number", "deleted-parent"].contains(mutation.entityId)
                return PushResult(mutationId: mutation.mutationId, status: rejected ? "rejected" : "applied", reason: rejected ? "VALIDATION_FAILED" : nil, entity: nil)
            }, serverTime: 1000)
        }
        await engine.push()
        let sent = api.pushCalls.flatMap { $0 }
        #expect(sent.map(\.entityId) == fixtures.map(\.id))
        #expect(Set(sent.map(\.mutationId)).count == fixtures.count)
        for (mutation, fixture) in zip(sent, fixtures) {
            let actual = try JSONSerialization.jsonObject(with: JSONEncoder().encode(mutation.payload)) as? NSDictionary
            let expected = try JSONSerialization.jsonObject(with: Data(fixture.payload.utf8)) as? NSDictionary
            #expect(actual == expected)
        }
        let retained = try ModelContext(context.container).fetch(FetchDescriptor<OutboxMutation>())
        #expect(retained.count == 4 && retained.allSatisfy { $0.status == "failed" })
        #expect(Set(retained.map(\.entityId)) == ["not-pending", "missing", "number", "deleted-parent"])
    }

}
