import Foundation
import SwiftData
import Testing
@testable import Snapceipt

@MainActor @Suite("Real v1 disk upgrade")
struct ClientWorkspaceUpgradeTests {
    private func id(_ n: Int) -> String { String(format: "01990000-0000-7000-8000-%012d", n) }
    @Test func baselineDiskStoreMigratesPreservingSnapshots() throws {
        let source = try #require(Bundle(for: GoldenAnchor.self).url(forResource: "v1-workspace", withExtension: "store"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("upgrade.store")
        try FileManager.default.copyItem(at: source, to: url)
        // Throw on migration failure: deliberately bypass the launch helper's memory fallback.
        let config = ModelConfiguration(schema: SnapceiptSchema.schema, url: url)
        let container = try ModelContainer(for: SnapceiptSchema.schema, configurations: [config])
        #expect(container.configurations.allSatisfy { !$0.isStoredInMemoryOnly && $0.url == url })
        let context = ModelContext(container)
        let profile = try #require(context.fetch(FetchDescriptor<Profile>()).only)
        #expect(profile.id == id(1) && profile.name == "V1 business" && profile.type == "business")
        let receipt = try #require(context.fetch(FetchDescriptor<Transaction>()).only)
        #expect(receipt.id == id(2) && receipt.merchant == "Original receipt" && receipt.amountCents == -12345)
        #expect(receipt.txnDate == "2026-09-01" && receipt.note == "Original receipt note" && receipt.gstCents == 1122)
        let client = try #require(context.fetch(FetchDescriptor<Client>()).only)
        #expect(client.id == id(3) && client.name == "Original client" && client.email == "old@example.test")
        #expect(client.address == "Original address" && client.mobilePhone == "0400123456" && client.notes == nil)
        let quote = try #require(context.fetch(FetchDescriptor<Quote>()).only)
        #expect(quote.id == id(4) && quote.number == "Q-V1" && quote.clientId == nil && quote.status == "sent")
        #expect(quote.clientName == "Quote snapshot" && quote.clientEmail == "quote@example.test" && quote.clientAddress == "Quote address" && quote.clientMobile == "0400000001")
        #expect(quote.subtotalCents == 20000 && quote.gstCents == 2000 && quote.totalCents == 22000 && quote.gstRateBp == 1000)
        #expect(quote.validUntil == "2026-09-30" && quote.sentAt == 1720000000000 && quote.pdfR2Key == "v1/quote.pdf")
        let qLine = try #require(context.fetch(FetchDescriptor<QuoteLineItem>()).only)
        #expect(qLine.id == id(5) && qLine.quoteId == quote.id && qLine.itemDescription == "Quote original work")
        #expect(qLine.quantity == 2 && qLine.unitPriceCents == 10000 && qLine.unitLabel == nil)
        let invoice = try #require(context.fetch(FetchDescriptor<Invoice>()).only)
        #expect(invoice.id == id(6) && invoice.quoteId == quote.id && invoice.number == "INV-V1" && invoice.clientId == nil)
        #expect(invoice.clientName == "Invoice snapshot" && invoice.clientEmail == "invoice@example.test" && invoice.status == "issued")
        #expect(invoice.subtotalCents == 30000 && invoice.gstCents == 3000 && invoice.totalCents == 33000 && invoice.gstRateBp == 1000)
        #expect(invoice.issueDate == "2026-09-01" && invoice.dueDate == "2026-09-15" && invoice.issuedAt == 1720000000001 && invoice.pdfR2Key == "v1/invoice.pdf")
        let iLine = try #require(context.fetch(FetchDescriptor<InvoiceLineItem>()).only)
        #expect(iLine.id == id(7) && iLine.invoiceId == invoice.id && iLine.itemDescription == "Invoice original work")
        #expect(iLine.quantity == 3 && iLine.unitPriceCents == 10000 && iLine.unitLabel == nil)
        let payment = try #require(context.fetch(FetchDescriptor<Payment>()).only)
        #expect(payment.id == id(8) && payment.invoiceId == invoice.id && payment.amountCents == 12000)
        #expect(payment.paidOn == "2026-09-02" && payment.method == "bank" && payment.note == "Original payment")
        let line = try #require(context.fetch(FetchDescriptor<LineItem>()).only)
        #expect(line.id == id(9) && line.transactionId == receipt.id && line.name == "Receipt original work" && line.priceCents == 12345)
        for row: any Syncable in [profile, receipt, client, quote, qLine, invoice, iLine, payment, line] {
            #expect(row.userId == "v1-upgrade-user")
        }
        for row: any Syncable in [profile, receipt, client, quote, invoice] { #expect(row.profileId == id(1) || row.entityType == .profile) }
        #expect(try context.fetch(FetchDescriptor<CatalogItem>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<ClientFollowUp>()).isEmpty)
        client.notes = "Added after upgrade"; try context.save()
        let reopened = try ModelContainer(for: SnapceiptSchema.schema, configurations: [config])
        #expect(try ModelContext(reopened).fetch(FetchDescriptor<Client>()).only?.notes == "Added after upgrade")
    }
}
private extension Array { var only: Element? { count == 1 ? first : nil } }
