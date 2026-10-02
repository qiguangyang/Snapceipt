import Foundation
import SwiftData
import Testing
@testable import Snapceipt

@MainActor
@Suite(.serialized)
struct V2AuthoritativePullTests {
    private func makeEngine() throws -> (SyncEngine, ModelContext, MockAPIClient) {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        let context = ModelContext(container)
        let api = MockAPIClient()
        UserDefaults.standard.removeObject(forKey: "sc.syncCursor")
        return (SyncEngine(api: api, context: context, auth: AuthStore(), toast: ToastCenter()), context, api)
    }

    private func envelope(type: String = "quote", id: String, rev: Int = 3, updatedAt: Int = 1000,
                          status: String = "sent", pdf: String = "authoritative.pdf") throws -> PullChange {
        let fields: [String: Any] = [
            "type": type, "id": id, "userId": "u1", "profileId": "p1",
            "rev": rev, "createdAt": 100, "updatedAt": updatedAt,
            "deletedAt": NSNull(), "lastEditedDeviceId": NSNull(),
            "status": status, "pdfR2Key": pdf, "clientName": "Server snapshot",
        ]
        return try JSONDecoder().decode(PullChange.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    private func acknowledge(_ engine: SyncEngine, _ api: MockAPIClient, rows: [any Syncable]) async throws {
        for row in rows { engine.enqueue(op: "upsert", entityType: row.entityType, entity: row) }
        api.pushHandler = { mutations in
            PushResponse(results: try mutations.map { mutation in
                PushResult(mutationId: mutation.mutationId, status: "applied", reason: nil,
                           entity: try self.envelope(type: mutation.entityType, id: mutation.entityId,
                                                     status: "draft", pdf: "old.pdf"))
            }, serverTime: 1000)
        }
        await engine.push()
    }

    @Test func appliedAckThenEqualTimestampPullRestoresQuoteAndInvoiceFields() async throws {
        let (engine, context, api) = try makeEngine()
        let quote = Quote(userId: "u1", profileId: "p1", pdfR2Key: "old.pdf", updatedAt: 500, rev: 2)
        let invoice = Invoice(userId: "u1", profileId: "p1", pdfR2Key: "old.pdf", updatedAt: 500, rev: 2)
        context.insert(quote); context.insert(invoice)
        try await acknowledge(engine, api, rows: [quote, invoice])
        #expect(quote.updatedAt == 1000 && invoice.updatedAt == 1000)
        #expect(quote.rev == 3 && invoice.rev == 3)
        #expect(try context.fetch(FetchDescriptor<OutboxMutation>()).isEmpty)

        api.pullPages = [PullResponse(changes: [
            try envelope(id: quote.id),
            try envelope(type: "invoice", id: invoice.id, status: "issued"),
        ], nextCursor: "AUTHORITATIVE", hasMore: false, serverTime: 1000)]
        await engine.pull()
        #expect(quote.pdfR2Key == "authoritative.pdf" && quote.status == "sent")
        #expect(invoice.pdfR2Key == "authoritative.pdf" && invoice.status == "issued")
        #expect(quote.clientName == "Server snapshot" && invoice.clientName == "Server snapshot")
    }

    @Test(arguments: ["pending", "inflight"])
    func equalTimestampPullProtectsUnsyncedEditsAfterAck(outboxStatus: String) async throws {
        let (engine, context, api) = try makeEngine()
        let quote = Quote(userId: "u1", profileId: "p1", pdfR2Key: "old.pdf", updatedAt: 500, rev: 2)
        context.insert(quote)
        try await acknowledge(engine, api, rows: [quote])
        quote.clientName = "Unsynced local snapshot"
        engine.enqueue(op: "upsert", entityType: .quote, entity: quote)
        let outbox = try context.fetch(FetchDescriptor<OutboxMutation>())
        outbox[0].status = outboxStatus
        try context.save()
        api.pullPages = [PullResponse(changes: [try envelope(id: quote.id)],
                                     nextCursor: "PROTECTED", hasMore: false, serverTime: 1000)]
        await engine.pull()
        #expect(quote.clientName == "Unsynced local snapshot")
        #expect(quote.pdfR2Key == "old.pdf" && quote.status == "draft")
        #expect(outbox[0].status == outboxStatus)
    }

    @Test(arguments: [1000, 2000])
    func olderRevisionNeverOverwritesLocal(updatedAt: Int) async throws {
        let (engine, context, api) = try makeEngine()
        let quote = Quote(userId: "u1", profileId: "p1", status: "sent", pdfR2Key: "current.pdf", updatedAt: 1000, rev: 5)
        context.insert(quote); try context.save()
        api.pullPages = [PullResponse(changes: [try envelope(id: quote.id, rev: 4, updatedAt: updatedAt, status: "draft", pdf: "older.pdf")],
                                     nextCursor: "OLDER", hasMore: false, serverTime: updatedAt)]
        await engine.pull()
        #expect(quote.rev == 5 && quote.updatedAt == 1000)
        #expect(quote.pdfR2Key == "current.pdf" && quote.status == "sent")
    }

    @Test func strictlyNewerLocalTimestampStillWins() async throws {
        let (engine, context, api) = try makeEngine()
        let quote = Quote(userId: "u1", profileId: "p1", status: "draft", updatedAt: 2000, rev: 2)
        context.insert(quote); try context.save()
        api.pullPages = [PullResponse(changes: [try envelope(id: quote.id, rev: 3, updatedAt: 1000)],
                                     nextCursor: "OLDER_TIME", hasMore: false, serverTime: 1000)]
        await engine.pull()
        #expect(quote.rev == 2 && quote.updatedAt == 2000 && quote.status == "draft")
    }

    @Test func equalTimestampNewerRevisionApplies() async throws {
        let (engine, context, api) = try makeEngine()
        let quote = Quote(userId: "u1", profileId: "p1", updatedAt: 1000, rev: 2)
        context.insert(quote); try context.save()
        api.pullPages = [PullResponse(changes: [try envelope(id: quote.id)],
                                     nextCursor: "NEWER_REV", hasMore: false, serverTime: 1000)]
        await engine.pull()
        #expect(quote.rev == 3 && quote.status == "sent" && quote.pdfR2Key == "authoritative.pdf")
    }
}
