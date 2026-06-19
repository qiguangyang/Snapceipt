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
struct QuoteSyncTests {
    @Test("quote upsert payload carries the gstInclusive flag")
    func quotePayloadCarriesGstInclusive() throws {
        let (engine, context, _) = try makeEngine()
        let q = Quote(userId: "u1", profileId: "p1", gstEnabled: true, gstInclusive: true)
        context.insert(q)
        engine.enqueue(op: "upsert", entityType: .quote, entity: q)
        let outbox = try context.fetch(FetchDescriptor<OutboxMutation>())
        #expect(outbox[0].payloadJSON.contains("\"gstInclusive\":true"))
    }

    /// The pull route serializes D1 INTEGER booleans straight back as JSON NUMBERS
    /// (0/1), not JSON booleans — so the apply path must coerce them. This guards the
    /// `PullChange.bool` numeric coercion: without it gstInclusive/gstEnabled would
    /// silently never apply on a cross-device pull.
    @Test("quote pull applies gstInclusive + gstEnabled from numeric 0/1 (real D1 shape)")
    func quotePullCoercesNumericFlags() async throws {
        let (engine, context, api) = try makeEngine()
        let id = ID.uuidv7()
        api.pullPages = [PullResponse(
            changes: [envelope(type: "quote", id: id, rev: 3, updatedAt: 9000,
                               extra: ["profileId": "p1", "clientName": "Jane",
                                       "gstEnabled": 1, "gstInclusive": 1,
                                       "subtotalCents": 19091, "gstCents": 1909, "totalCents": 21000,
                                       "currency": "AUD", "status": "draft"])],
            nextCursor: "C1", hasMore: false, serverTime: 9000)]
        await engine.pull()
        let row = try context.fetch(FetchDescriptor<Quote>(predicate: #Predicate { $0.id == id })).first!
        #expect(row.gstInclusive == true)
        #expect(row.gstEnabled == true)
        #expect(row.totalCents == 21000)
    }

    @Test("numeric 0 coerces to false on pull")
    func quotePullCoercesZero() async throws {
        let (engine, context, api) = try makeEngine()
        let id = ID.uuidv7()
        api.pullPages = [PullResponse(
            changes: [envelope(type: "quote", id: id, rev: 1, updatedAt: 1000,
                               extra: ["profileId": "p1", "gstEnabled": 1, "gstInclusive": 0,
                                       "status": "draft", "currency": "AUD"])],
            nextCursor: "C2", hasMore: false, serverTime: 1000)]
        await engine.pull()
        let row = try context.fetch(FetchDescriptor<Quote>(predicate: #Predicate { $0.id == id })).first!
        #expect(row.gstInclusive == false)
    }

    /// The quote→PDF→invoice link columns added in backend migration 0009
    /// (`quotes.pdf_r2_key` + `quotes.invoice_id`) must round-trip both ways using the
    /// camelCase wire keys `pdfR2Key`/`invoiceId` the backend `rowToEntity` emits.
    @Test("quote payload carries pdfR2Key + invoiceId; pull restores them")
    func quoteRoundTripsPdfR2KeyAndInvoiceId() async throws {
        let (engine, context, api) = try makeEngine()
        let q = Quote(userId: "u1", profileId: "p1")
        q.pdfR2Key = "r2/key.pdf"
        q.invoiceId = "inv1"
        context.insert(q)
        engine.enqueue(op: "upsert", entityType: .quote, entity: q)
        let json = try context.fetch(FetchDescriptor<OutboxMutation>())[0].payloadJSON
        // JSONEncoder escapes the forward slash in the R2 key as `\/`.
        #expect(json.contains(#""pdfR2Key":"r2\/key.pdf""#))
        #expect(json.contains(#""invoiceId":"inv1""#))

        let id = ID.uuidv7()
        api.pullPages = [PullResponse(
            changes: [envelope(type: "quote", id: id, rev: 1, updatedAt: 2000,
                               extra: ["profileId": "p1", "status": "invoiced", "currency": "AUD",
                                       "gstEnabled": 1, "gstInclusive": 0,
                                       "pdfR2Key": "r2/x.pdf", "invoiceId": "inv9"])],
            nextCursor: "C3", hasMore: false, serverTime: 2000)]
        await engine.pull()
        let row = try context.fetch(FetchDescriptor<Quote>(predicate: #Predicate { $0.id == id })).first!
        #expect(row.pdfR2Key == "r2/x.pdf")
        #expect(row.invoiceId == "inv9")
    }
}
