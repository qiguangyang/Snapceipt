import Testing
import SwiftData
@testable import Snapceipt

@MainActor
@Suite("ClientHistory")
struct ClientHistoryTests {
    @Test func historyUsesIdsNotContactEquality() throws {
        let ctx = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        let own = Quote(userId: "u1", profileId: "p1", clientId: "c1", clientName: "Same", clientEmail: "same@example.com", createdAt: 10)
        let invoice = Invoice(userId: "u1", profileId: "p1", clientId: "c1", clientName: "Same", createdAt: 20)
        let excluded = [
            Quote(userId: "u1", profileId: "p1", clientId: "c2", clientName: "Same", clientEmail: "same@example.com"),
            Quote(userId: "u2", profileId: "p1", clientId: "c1"),
            Quote(userId: "u1", profileId: "p2", clientId: "c1"),
            Quote(userId: "u1", profileId: "p1", clientName: "Same"),
            Quote(userId: "u1", profileId: "p1", clientId: "c1", deletedAt: 1)
        ]
        ctx.insert(own); ctx.insert(invoice)
        for q in excluded { ctx.insert(q) }
        ctx.insert(Invoice(userId: "u2", profileId: "p1", clientId: "c1"))
        ctx.insert(Invoice(userId: "u1", profileId: "p2", clientId: "c1"))
        ctx.insert(Invoice(userId: "u1", profileId: "p1", clientId: "c2"))
        ctx.insert(Invoice(userId: "u1", profileId: "p1", clientId: "c1", deletedAt: 1))
        try ctx.save()
        let result = try ClientHistory.load(context: ctx, userId: "u1", profileId: "p1", clientId: "c1", today: "2026-10-01")
        #expect(result.documents.map(\.id) == [invoice.id, own.id])
        #expect(result.documents.map(\.kind) == [.invoice, .quote])
    }

    @Test func outstandingUsesLiveIssuedInvoices() throws {
        let ctx = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        let a = Invoice(userId: "u1", profileId: "p1", clientId: "c1", totalCents: 10_000, status: "issued", dueDate: "2026-09-01")
        let b = Invoice(userId: "u1", profileId: "p1", clientId: "c1", totalCents: 5_000, status: "issued")
        for invoice in [a, b, Invoice(userId: "u1", profileId: "p1", clientId: "c1", totalCents: 9_000, status: "draft"), Invoice(userId: "u1", profileId: "p1", clientId: "c1", totalCents: 8_000, status: "void"), Invoice(userId: "u1", profileId: "p1", clientId: "c1", totalCents: 7_000, status: "issued", deletedAt: 1)] { ctx.insert(invoice) }
        for payment in [Payment(userId: "u1", invoiceId: a.id, amountCents: 3_000, paidOn: "2026-09-30"), Payment(userId: "u1", invoiceId: b.id, amountCents: 6_000, paidOn: "2026-09-30"), Payment(userId: "u1", invoiceId: a.id, amountCents: 2_000, paidOn: "2026-09-30", deletedAt: 1), Payment(userId: "u2", invoiceId: a.id, amountCents: 9_000, paidOn: "2026-09-30"), Payment(userId: "u1", invoiceId: "other", amountCents: 9_000, paidOn: "2026-09-30")] { ctx.insert(payment) }
        try ctx.save()
        let result = try ClientHistory.load(context: ctx, userId: "u1", profileId: "p1", clientId: "c1", today: "2026-10-01")
        #expect(result.outstandingCents == 7_000)
        #expect(result.outstandingByCurrency == ["AUD": 7_000])
        #expect(result.documents.first { $0.id == a.id }?.paymentState == .partial)
        #expect(result.documents.first { $0.id == b.id }?.paymentState == .paid)
    }
}

@MainActor struct ClientHistoryCurrencyTests {
    @Test func documentHistoryRetainsEachDocumentsCurrency() throws {
        let context = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        context.insert(Quote(userId: "u", profileId: "p", clientId: "c", totalCents: 100, currency: "NZD"))
        context.insert(Invoice(userId: "u", profileId: "p", clientId: "c", totalCents: 100, currency: "USD"))
        try context.save()
        let history = try ClientHistory.load(context: context, userId: "u", profileId: "p", clientId: "c", today: "2026-10-01")
        #expect(Set(history.documents.map(\.currency)) == ["NZD", "USD"])
    }
}

@MainActor struct ClientOutstandingCurrencyTests {
    @Test func outstandingKeepsCurrenciesSeparateUsingScopedIssuedPayments() throws {
        let context = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        let nzd = Invoice(userId: "u", profileId: "p", clientId: "c", totalCents: 10000, currency: "NZD", status: "issued")
        let usd = Invoice(userId: "u", profileId: "p", clientId: "c", totalCents: 5000, currency: "USD", status: "issued")
        for row in [nzd, usd,
            Invoice(userId: "u", profileId: "p", clientId: "c", totalCents: 99999, currency: "AUD", status: "draft"),
            Invoice(userId: "u", profileId: "p", clientId: "c", totalCents: 99999, currency: "AUD", status: "void"),
            Invoice(userId: "u", profileId: "foreign", clientId: "c", totalCents: 99999, currency: "AUD", status: "issued"),
            Invoice(userId: "foreign", profileId: "p", clientId: "c", totalCents: 99999, currency: "AUD", status: "issued"),
            Invoice(userId: "u", profileId: "p", clientId: "foreign", totalCents: 99999, currency: "AUD", status: "issued"),
            Invoice(userId: "u", profileId: "p", clientId: "c", totalCents: 99999, currency: "AUD", status: "issued", deletedAt: 1)] { context.insert(row) }
        for payment in [Payment(userId: "u", invoiceId: nzd.id, amountCents: 3000, paidOn: "2026-10-01"),
            Payment(userId: "u", invoiceId: usd.id, amountCents: 1000, paidOn: "2026-10-01"),
            Payment(userId: "foreign", invoiceId: nzd.id, amountCents: 7000, paidOn: "2026-10-01"),
            Payment(userId: "u", invoiceId: usd.id, amountCents: 4000, paidOn: "2026-10-01", deletedAt: 1)] { context.insert(payment) }
        try context.save()
        let result = try ClientHistory.load(context: context, userId: "u", profileId: "p", clientId: "c", today: "2026-10-01")
        #expect(result.outstandingByCurrency == ["NZD": 7000, "USD": 4000])
        #expect(result.documents.first { $0.id == nzd.id }?.paymentState == .partial)
        #expect(result.documents.first { $0.id == usd.id }?.paymentState == .partial)
    }
}
