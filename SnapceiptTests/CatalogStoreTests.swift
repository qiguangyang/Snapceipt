import Foundation
import SwiftData
import Testing
@testable import Snapceipt

@MainActor @Suite(.serialized) struct CatalogStoreTests {
    private func fixture() throws -> (ModelContext, MockSyncEngine) {
        let context = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        context.autosaveEnabled = false
        return (context, MockSyncEngine())
    }
    @Test func catalogIsScopedAndSnapshotsInsertedLines() throws {
        let (context, sync) = try fixture()
        let store = CatalogStore(context: context, sync: sync, userId: "u1", profileId: "p1")
        let item = try store.save(id: nil, description: "Design", unitLabel: "hour", unitPriceCents: 10000)
        _ = try CatalogStore(context: context, sync: sync, userId: "u2", profileId: "p1").save(id: nil, description: "Foreign", unitLabel: nil, unitPriceCents: 10)
        _ = try CatalogStore(context: context, sync: sync, userId: "u1", profileId: "p2").save(id: nil, description: "Other", unitLabel: nil, unitPriceCents: 10)
        #expect(try store.list(search: "DES").map(\.id) == [item.id])
        let quote = QuoteEditorViewModel(context: context, sync: sync, userId: "u1", profileId: "p1")
        let invoice = InvoiceEditorViewModel(context: context, sync: sync, userId: "u1", profileId: "p1")
        quote.load(id: nil); invoice.load(id: nil); quote.gstInclusive = true; invoice.gstInclusive = true
        let qid = try quote.addCatalogItem(item), iid = try invoice.addCatalogItem(item)
        #expect(quote.lineItems[0].id == qid && invoice.lineItems[0].id == iid)
        #expect(quote.lineItems[0].quantity == 1 && invoice.lineItems[0].quantity == 1)
        #expect(quote.lineItems[0].unitPriceCents == 11000 && invoice.lineItems[0].unitPriceCents == 11000)
        #expect(quote.saveDraft() && invoice.saveDraft())
        _ = try store.save(id: item.id, description: "Changed", unitLabel: "day", unitPriceCents: 500)
        try store.delete(id: item.id)
        #expect(try store.list(search: "").isEmpty)
        #expect(quote.lineItems[0].itemDescription == "Design" && quote.lineItems[0].unitLabel == "hour")
        #expect(invoice.lineItems[0].itemDescription == "Design" && invoice.lineItems[0].unitLabel == "hour")
        let reader = ModelContext(context.container)
        #expect(try reader.fetch(FetchDescriptor<QuoteLineItem>()).first?.unitLabel == "hour")
        #expect(try reader.fetch(FetchDescriptor<InvoiceLineItem>()).first?.unitLabel == "hour")
        #expect(try reader.fetch(FetchDescriptor<QuoteLineItem>()).first?.unitPriceCents == 11000)
        #expect(try reader.fetch(FetchDescriptor<InvoiceLineItem>()).first?.itemDescription == "Design")
        #expect(throws: CatalogStore.ValidationError.self) { try quote.addCatalogItem(item) }
        #expect(throws: CatalogStore.ValidationError.self) { try invoice.addCatalogItem(item) }
    }
    @Test func invalidFieldsAndForeignIdsRejected() throws {
        let (context, sync) = try fixture()
        let store = CatalogStore(context: context, sync: sync, userId: "u1", profileId: "p1")
        for description in [" ", String(repeating: "a", count: 501)] {
            #expect(throws: CatalogStore.ValidationError.self) { try store.save(id: nil, description: description, unitLabel: nil, unitPriceCents: 0) }
        }
        #expect(throws: CatalogStore.ValidationError.self) { try store.save(id: nil, description: "Work", unitLabel: String(repeating: "a", count: 41), unitPriceCents: 0) }
        #expect(throws: CatalogPrice.ValidationError.self) { try store.save(id: nil, description: "Work", unitLabel: nil, unitPriceCents: -1) }
        #expect(throws: CatalogStore.ValidationError.self) { try store.delete(id: "foreign") }
        #expect(throws: CatalogStore.ValidationError.self) { try store.save(id: nil, description: String(repeating: "🛠", count: 251), unitLabel: nil, unitPriceCents: 0) }
        #expect(throws: CatalogStore.ValidationError.self) { try store.save(id: nil, description: "Work", unitLabel: String(repeating: "🛠", count: 21), unitPriceCents: 0) }
        #expect(sync.calls.isEmpty)
    }
}

@MainActor @Suite(.serialized) struct CatalogAtomicSaveTests {
    @Test func createEditDeleteFailuresAreAtomicAndRetryable() throws {
        let context = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        context.autosaveEnabled = false
        let notes = Client(userId: "u1", profileId: "p1", name: "Other", notes: "Saved")
        context.insert(notes); try context.save()
        let engine = SyncEngine(api: MockAPIClient(), context: context, auth: AuthStore(), toast: ToastCenter())
        var fail = true, staged = 0
        enum Failure: Error { case save }
        let store = CatalogStore(context: context, sync: engine, userId: "u1", profileId: "p1", persist: { transaction in
            staged = try transaction.fetch(FetchDescriptor<OutboxMutation>()).count
            if fail { throw Failure.save }
            try transaction.save()
        })
        notes.notes = "Pending"
        #expect(throws: Failure.self) { try store.save(id: nil, description: "Work", unitLabel: "hour", unitPriceCents: 100) }
        #expect(staged == 1)
        let failed = ModelContext(context.container)
        #expect(try failed.fetch(FetchDescriptor<CatalogItem>()).isEmpty)
        #expect(try failed.fetch(FetchDescriptor<OutboxMutation>()).isEmpty)
        fail = false
        let item = try store.save(id: nil, description: "Work", unitLabel: "hour", unitPriceCents: 100)
        fail = true
        #expect(throws: Failure.self) { try store.save(id: item.id, description: "Changed", unitLabel: "day", unitPriceCents: 200) }
        #expect(throws: Failure.self) { try store.delete(id: item.id) }
        let reader = ModelContext(context.container)
        #expect(try reader.fetch(FetchDescriptor<CatalogItem>()).first?.itemDescription == "Work")
        #expect(try reader.fetch(FetchDescriptor<CatalogItem>()).first?.deletedAt == nil)
        #expect(try reader.fetch(FetchDescriptor<OutboxMutation>()).count == 1)
        #expect(try reader.fetch(FetchDescriptor<OutboxMutation>()).first?.payloadJSON.contains("Changed") == false)
        #expect(try reader.fetch(FetchDescriptor<Client>()).first?.notes == "Saved")
        fail = false
        _ = try store.save(id: item.id, description: "Changed", unitLabel: "day", unitPriceCents: 200)
        try store.delete(id: item.id)
        let saved = ModelContext(context.container)
        #expect(try saved.fetch(FetchDescriptor<CatalogItem>()).first?.deletedAt != nil)
        #expect(try saved.fetch(FetchDescriptor<OutboxMutation>()).count == 2)
        #expect(notes.notes == "Pending")
    }
}
