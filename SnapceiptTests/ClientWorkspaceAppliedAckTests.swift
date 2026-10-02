import Foundation
import SwiftData
import Testing
@testable import Snapceipt

@MainActor @Suite(.serialized)
struct ClientWorkspaceAppliedAckTests {
    @Test(arguments: [false, true])
    func loadedDraftEditsAndDeletesSurviveRealEngineAcknowledgement(invoice: Bool) async throws {
        let context = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        context.autosaveEnabled = false
        let auth = AuthStore(keychain: Keychain(service: "task10-ack-" + UUID().uuidString))
        auth.save(SessionResponse(accessToken: "test", refreshToken: "test", expiresIn: 900, user: SessionUser(id: "u1", email: nil, displayName: nil)))
        defer { auth.clear() }
        let api = MockAPIClient()
        let engine = SyncEngine(api: api, context: context, auth: auth, toast: ToastCenter())
        let unrelated = Client(userId: "u1", profileId: "other-profile", name: "Other", notes: "Saved")
        context.insert(unrelated)
        var keptId = "", removedId = "", parentId = ""
        if invoice {
            let parent = Invoice(userId: "u1", profileId: "p1", clientName: "Before")
            let keep = InvoiceLineItem(userId: "u1", invoiceId: parent.id, itemDescription: "Old", unitLabel: "hour", unitPriceCents: 100)
            let remove = InvoiceLineItem(userId: "u1", invoiceId: parent.id, itemDescription: "Remove", unitPriceCents: 900)
            context.insert(parent); context.insert(keep); context.insert(remove); try context.save()
            for row: any Syncable in [parent, keep, remove] { engine.enqueue(op: "upsert", entityType: row.entityType, entity: row) }
            // Retain loaded model and outbox objects so the engine must refresh stale cache snapshots.
            let cached = try context.fetch(FetchDescriptor<OutboxMutation>())
            #expect(cached.count == 3 && cached.contains { $0.payloadJSON.contains("Old") })
            let editor = InvoiceEditorViewModel(context: context, sync: engine, userId: "u1", profileId: "p1")
            editor.load(id: parent.id); editor.setClient(name: "After", email: "new@example.test")
            let line = try #require(editor.lineItems.first { $0.id == keep.id })
            line.itemDescription = "Edited"; line.unitLabel = "day"; line.quantity = 3; line.unitPriceCents = 250
            editor.removeLine(try #require(editor.lineItems.first { $0.id == remove.id }))
            #expect(editor.saveDraft())
            keptId = keep.id; removedId = remove.id; parentId = parent.id
        } else {
            let parent = Quote(userId: "u1", profileId: "p1", clientName: "Before")
            let keep = QuoteLineItem(userId: "u1", quoteId: parent.id, itemDescription: "Old", unitLabel: "hour", unitPriceCents: 100)
            let remove = QuoteLineItem(userId: "u1", quoteId: parent.id, itemDescription: "Remove", unitPriceCents: 900)
            context.insert(parent); context.insert(keep); context.insert(remove); try context.save()
            for row: any Syncable in [parent, keep, remove] { engine.enqueue(op: "upsert", entityType: row.entityType, entity: row) }
            let cached = try context.fetch(FetchDescriptor<OutboxMutation>())
            #expect(cached.count == 3 && cached.contains { $0.payloadJSON.contains("Old") })
            let editor = QuoteEditorViewModel(context: context, sync: engine, userId: "u1", profileId: "p1")
            editor.load(id: parent.id); editor.setClient(name: "After", email: "new@example.test")
            let line = try #require(editor.lineItems.first { $0.id == keep.id })
            line.itemDescription = "Edited"; line.unitLabel = "day"; line.quantity = 3; line.unitPriceCents = 250
            editor.removeLine(try #require(editor.lineItems.first { $0.id == remove.id }))
            #expect(editor.saveDraft())
            keptId = keep.id; removedId = remove.id; parentId = parent.id
        }
        api.pushHandler = { mutations in
            PushResponse(results: try mutations.map { mutation in
                let envelope = try JSONDecoder().decode(PullChange.self, from: JSONSerialization.data(withJSONObject: ["type": mutation.entityType, "id": mutation.entityId, "userId": "u1", "createdAt": 100, "rev": 7, "updatedAt": 1800000000000]))
                return PushResult(mutationId: mutation.mutationId, status: "applied", reason: nil, entity: envelope)
            }, serverTime: 1800000000000)
        }
        await engine.flush()
        let sent = api.pushCalls.flatMap { $0 }
        #expect(sent.contains { $0.entityId == removedId && $0.op == "delete" })
        let kept = try #require(sent.last { $0.entityId == keptId })
        let fields = try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(kept.payload))
        #expect(fields[invoice ? "itemDescription" : "description"]?.stringValue == "Edited")
        #expect(fields["unitLabel"]?.stringValue == "day")
        let reader = ModelContext(context.container)
        #expect(try reader.fetch(FetchDescriptor<OutboxMutation>()).isEmpty)
        if invoice {
            let lines = try reader.fetch(FetchDescriptor<InvoiceLineItem>())
            let line = try #require(lines.first { $0.id == keptId })
            #expect(line.itemDescription == "Edited" && line.unitLabel == "day" && line.quantity == 3 && line.unitPriceCents == 250 && line.rev == 7)
            #expect(lines.first { $0.id == removedId }?.deletedAt != nil)
            let parent = try #require(reader.fetch(FetchDescriptor<Invoice>()).first { $0.id == parentId })
            #expect(parent.clientName == "After" && parent.totalCents == 825 && parent.rev == 7)
        } else {
            let lines = try reader.fetch(FetchDescriptor<QuoteLineItem>())
            let line = try #require(lines.first { $0.id == keptId })
            #expect(line.itemDescription == "Edited" && line.unitLabel == "day" && line.quantity == 3 && line.unitPriceCents == 250 && line.rev == 7)
            #expect(lines.first { $0.id == removedId }?.deletedAt != nil)
            let parent = try #require(reader.fetch(FetchDescriptor<Quote>()).first { $0.id == parentId })
            #expect(parent.clientName == "After" && parent.totalCents == 825 && parent.rev == 7)
        }
        #expect(try reader.fetch(FetchDescriptor<Client>()).first?.notes == "Saved")
        #expect(try reader.fetch(FetchDescriptor<Payment>()).isEmpty)
        #expect(try reader.fetch(FetchDescriptor<Transaction>()).isEmpty)
    }
}
