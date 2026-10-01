import Foundation
import SwiftData

// Compiled as module Snapceipt with ONLY the archived v1 production model sources.
@main struct V1WorkspaceFixture {
    @MainActor static func main() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let config = ModelConfiguration(schema: SnapceiptSchema.schema, url: url)
        let container = try ModelContainer(for: SnapceiptSchema.schema, configurations: [config])
        let context = ModelContext(container)
        let user = "v1-upgrade-user", profile = id(1), receipt = id(2), quote = id(4), invoice = id(6)
        context.insert(Profile(id: profile, userId: user, name: "V1 business", type: "business", initials: "V1", accent1: "#112233", accent2: "#334455", accent3: "#556677"))
        context.insert(Transaction(id: receipt, userId: user, profileId: profile, merchant: "Original receipt", catKey: "office", amountCents: -12345, txnDate: "2026-09-01", note: "Original receipt note", gstCents: 1122))
        context.insert(Client(id: id(3), userId: user, profileId: profile, name: "Original client", email: "old@example.test", mobilePhone: "0400123456", address: "Original address"))
        context.insert(Quote(id: quote, userId: user, profileId: profile, number: "Q-V1", clientName: "Quote snapshot", clientEmail: "quote@example.test", clientAddress: "Quote address", clientMobile: "0400000001", subtotalCents: 20000, gstCents: 2000, totalCents: 22000, status: "sent", validUntil: "2026-09-30", sentAt: 1720000000000, pdfR2Key: "v1/quote.pdf", gstRateBp: 1000))
        context.insert(QuoteLineItem(id: id(5), userId: user, quoteId: quote, itemDescription: "Quote original work", quantity: 2, unitPriceCents: 10000))
        context.insert(Invoice(id: invoice, userId: user, profileId: profile, number: "INV-V1", quoteId: quote, clientName: "Invoice snapshot", clientEmail: "invoice@example.test", subtotalCents: 30000, gstCents: 3000, totalCents: 33000, status: "issued", issueDate: "2026-09-01", dueDate: "2026-09-15", issuedAt: 1720000000001, pdfR2Key: "v1/invoice.pdf", gstRateBp: 1000))
        context.insert(InvoiceLineItem(id: id(7), userId: user, invoiceId: invoice, itemDescription: "Invoice original work", quantity: 3, unitPriceCents: 10000))
        context.insert(Payment(id: id(8), userId: user, invoiceId: invoice, amountCents: 12000, paidOn: "2026-09-02", method: "bank", note: "Original payment"))
        context.insert(LineItem(id: id(9), userId: user, transactionId: receipt, name: "Receipt original work", priceCents: 12345))
        try context.save()
        print("Generated baseline disk store: \(url.path); models=\(SnapceiptSchema.models.count)")
    }
    static func id(_ n: Int) -> String { String(format: "01990000-0000-7000-8000-%012d", n) }
}
