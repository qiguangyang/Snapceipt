import Foundation
import SwiftData
import Testing
@testable import Snapceipt

@MainActor
@Suite("Invoice models")
struct InvoiceModelTests {
    private func ctx() throws -> ModelContext {
        ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
    }

    @Test("Invoice defaults: draft status, AUD, gst on, profileId set")
    func invoiceDefaults() throws {
        let c = try ctx()
        let inv = Invoice(userId: "u1", profileId: "p1")
        c.insert(inv)
        try c.save()
        let stored = try c.fetch(FetchDescriptor<Invoice>())[0]
        #expect(stored.status == "draft")
        #expect(stored.currency == "AUD")
        #expect(stored.gstEnabled == true)
        #expect(stored.profileId == "p1")
        #expect(stored.entityType == .invoice)
        #expect(stored.number == nil)
        #expect(stored.dueDate == nil)
    }

    @Test("InvoiceLineItem: profileId always nil, lineTotalCents = qty*unit")
    func lineItemTotals() throws {
        let c = try ctx()
        let line = InvoiceLineItem(userId: "u1", invoiceId: "inv1",
                                   itemDescription: "Design", quantity: 3, unitPriceCents: 100_00)
        c.insert(line)
        try c.save()
        let stored = try c.fetch(FetchDescriptor<InvoiceLineItem>())[0]
        #expect(stored.profileId == nil)
        #expect(stored.lineTotalCents == 300_00)
        #expect(stored.entityType == .invoiceLineItem)
    }

    @Test("Payment: stores amount/date/method/note, profileId nil")
    func paymentStores() throws {
        let c = try ctx()
        let pay = Payment(userId: "u1", invoiceId: "inv1", amountCents: 55_00,
                          paidOn: "2026-06-19", method: "bank", note: "deposit")
        c.insert(pay)
        try c.save()
        let stored = try c.fetch(FetchDescriptor<Payment>())[0]
        #expect(stored.amountCents == 55_00)
        #expect(stored.paidOn == "2026-06-19")
        #expect(stored.method == "bank")
        #expect(stored.note == "deposit")
        #expect(stored.profileId == nil)
        #expect(stored.entityType == .payment)
    }

    @Test("EntityType has the 3 new cases with the exact raw values")
    func entityTypeRawValues() {
        #expect(EntityType.invoice.rawValue == "invoice")
        #expect(EntityType.invoiceLineItem.rawValue == "invoiceLineItem")
        #expect(EntityType.payment.rawValue == "payment")
    }

    // MARK: - Sync mappers (spec §4.1 wire keys)

    @Test("InvoiceSyncMapper payload round-trips the invoice wire keys + shared envelope")
    func invoiceMapperRoundTrip() throws {
        let c = try ctx()
        let registry = SyncEntityRegistry()
        let inv = Invoice(userId: "u1", profileId: "p1", number: "INV-0001", quoteId: "q-1",
                          clientName: "Acme", clientEmail: "ap@acme.com", gstEnabled: true,
                          gstInclusive: false, subtotalCents: 50_000, gstCents: 5_000,
                          totalCents: 55_000, currency: "AUD", status: "issued",
                          issueDate: "2026-06-19", dueDate: "2026-07-03", issuedAt: 1_790_000_000_000,
                          pdfR2Key: "u/u1/inv.pdf")
        inv.rev = 4
        c.insert(inv)
        try c.save()

        let fields = registry.decodePayload(registry.encodePayload(entityType: .invoice, entity: inv))
        #expect(fields["number"]?.stringValue == "INV-0001")
        #expect(fields["quoteId"]?.stringValue == "q-1")
        #expect(fields["clientName"]?.stringValue == "Acme")
        #expect(fields["clientEmail"]?.stringValue == "ap@acme.com")
        #expect(fields["gstEnabled"]?.boolValue == true)
        #expect(fields["gstInclusive"]?.boolValue == false)
        #expect(fields["subtotalCents"]?.intValue == 50_000)
        #expect(fields["gstCents"]?.intValue == 5_000)
        #expect(fields["totalCents"]?.intValue == 55_000)
        #expect(fields["currency"]?.stringValue == "AUD")
        #expect(fields["status"]?.stringValue == "issued")
        #expect(fields["issueDate"]?.stringValue == "2026-06-19")
        #expect(fields["dueDate"]?.stringValue == "2026-07-03")
        #expect(fields["issuedAt"]?.intValue == 1_790_000_000_000)
        #expect(fields["pdfR2Key"]?.stringValue == "u/u1/inv.pdf")
        #expect(fields["profileId"]?.stringValue == "p1")
        #expect(fields["rev"]?.intValue == 4)
    }

    @Test("InvoiceSyncMapper upserts a pulled invoice envelope")
    func invoiceMapperUpsert() throws {
        let c = try ctx()
        let registry = SyncEntityRegistry()
        let envJSON = """
        {"type":"invoice","id":"inv-1","userId":"u1","profileId":"p1",
         "number":"INV-0007","quoteId":"q-9","clientName":"Beta Co","clientEmail":"b@co.com",
         "gstEnabled":true,"gstInclusive":false,"subtotalCents":10000,"gstCents":1000,
         "totalCents":11000,"currency":"AUD","status":"issued","issueDate":"2026-06-19",
         "dueDate":"2026-07-03","issuedAt":1790000000000,"pdfR2Key":"u/u1/x.pdf",
         "createdAt":1,"updatedAt":2,"deletedAt":null,"rev":5,"lastEditedDeviceId":null}
        """
        let env = try JSONDecoder().decode(PullChange.self, from: Data(envJSON.utf8))
        registry.handler(for: .invoice)?.applyPulled(c, env)
        try c.save()
        let stored = try c.fetch(FetchDescriptor<Invoice>())[0]
        #expect(stored.id == "inv-1")
        #expect(stored.number == "INV-0007")
        #expect(stored.quoteId == "q-9")
        #expect(stored.clientName == "Beta Co")
        #expect(stored.totalCents == 11000)
        #expect(stored.status == "issued")
        #expect(stored.issueDate == "2026-06-19")
        #expect(stored.pdfR2Key == "u/u1/x.pdf")
        #expect(stored.rev == 5)
    }

    @Test("InvoiceLineItemSyncMapper payload uses the wire key 'itemDescription'")
    func invoiceLineItemMapperRoundTrip() throws {
        let c = try ctx()
        let registry = SyncEntityRegistry()
        let line = InvoiceLineItem(userId: "u1", invoiceId: "inv1", itemDescription: "Design",
                                   quantity: 3, unitPriceCents: 100_00, sortOrder: 2)
        c.insert(line)
        try c.save()

        let fields = registry.decodePayload(registry.encodePayload(entityType: .invoiceLineItem, entity: line))
        // CRITICAL: backend invoiceLineItem wire key is `itemDescription` (rowToEntity emits
        // the columns-map KEY; for invoiceLineItem that key is `itemDescription`, NOT `description`).
        #expect(fields["itemDescription"]?.stringValue == "Design")
        #expect(fields["description"] == nil)
        #expect(fields["invoiceId"]?.stringValue == "inv1")
        #expect(fields["quantity"]?.intValue == 3)
        #expect(fields["unitPriceCents"]?.intValue == 100_00)
        #expect(fields["sortOrder"]?.intValue == 2)
    }

    @Test("InvoiceLineItemSyncMapper upserts a pulled envelope using 'itemDescription'")
    func invoiceLineItemMapperUpsert() throws {
        let c = try ctx()
        let registry = SyncEntityRegistry()
        let envJSON = """
        {"type":"invoiceLineItem","id":"il-1","userId":"u1",
         "invoiceId":"inv1","itemDescription":"Consulting","quantity":2,"unitPriceCents":7500,
         "sortOrder":1,"createdAt":1,"updatedAt":2,"deletedAt":null,"rev":3,"lastEditedDeviceId":null}
        """
        let env = try JSONDecoder().decode(PullChange.self, from: Data(envJSON.utf8))
        registry.handler(for: .invoiceLineItem)?.applyPulled(c, env)
        try c.save()
        let stored = try c.fetch(FetchDescriptor<InvoiceLineItem>())[0]
        #expect(stored.id == "il-1")
        #expect(stored.invoiceId == "inv1")
        #expect(stored.itemDescription == "Consulting")
        #expect(stored.quantity == 2)
        #expect(stored.unitPriceCents == 7500)
        #expect(stored.sortOrder == 1)
        #expect(stored.rev == 3)
    }

    @Test("PaymentSyncMapper payload round-trips the payment wire keys")
    func paymentMapperRoundTrip() throws {
        let c = try ctx()
        let registry = SyncEntityRegistry()
        let pay = Payment(userId: "u1", invoiceId: "inv1", amountCents: 55_00,
                          paidOn: "2026-06-19", method: "bank", note: "deposit")
        c.insert(pay)
        try c.save()

        let fields = registry.decodePayload(registry.encodePayload(entityType: .payment, entity: pay))
        #expect(fields["invoiceId"]?.stringValue == "inv1")
        #expect(fields["amountCents"]?.intValue == 55_00)
        #expect(fields["paidOn"]?.stringValue == "2026-06-19")
        #expect(fields["method"]?.stringValue == "bank")
        #expect(fields["note"]?.stringValue == "deposit")
    }

    @Test("PaymentSyncMapper upserts a pulled envelope")
    func paymentMapperUpsert() throws {
        let c = try ctx()
        let registry = SyncEntityRegistry()
        let envJSON = """
        {"type":"payment","id":"pay-1","userId":"u1",
         "invoiceId":"inv1","amountCents":4200,"paidOn":"2026-06-20","method":"card","note":null,
         "createdAt":1,"updatedAt":2,"deletedAt":null,"rev":1,"lastEditedDeviceId":null}
        """
        let env = try JSONDecoder().decode(PullChange.self, from: Data(envJSON.utf8))
        registry.handler(for: .payment)?.applyPulled(c, env)
        try c.save()
        let stored = try c.fetch(FetchDescriptor<Payment>())[0]
        #expect(stored.id == "pay-1")
        #expect(stored.invoiceId == "inv1")
        #expect(stored.amountCents == 4200)
        #expect(stored.paidOn == "2026-06-20")
        #expect(stored.method == "card")
        #expect(stored.rev == 1)
    }

    // MARK: - API DTOs (spec §6)

    @Test("IssueInvoiceResponse decodes the issue route JSON")
    func issueResponseDecodes() throws {
        let json = """
        {"pdfUrl":"/invoices/dl/tok","number":"INV-0001","status":"issued",
         "issueDate":"2026-06-19","dueDate":"2026-07-03","issuedAt":1790000000000,
         "subtotalCents":50000,"gstCents":5000,"totalCents":55000,"expiresAt":1790000000001}
        """
        let r = try JSONDecoder().decode(IssueInvoiceResponse.self, from: Data(json.utf8))
        #expect(r.number == "INV-0001")
        #expect(r.status == "issued")
        #expect(r.dueDate == "2026-07-03")
        #expect(r.totalCents == 55000)
    }

    @Test("GenerateQuotePdfResponse decodes a null number")
    func quotePdfResponseDecodes() throws {
        let json = #"{"pdfUrl":"/quotes/dl/tok","number":null,"expiresAt":null}"#
        let r = try JSONDecoder().decode(GenerateQuotePdfResponse.self, from: Data(json.utf8))
        #expect(r.pdfUrl == "/quotes/dl/tok")
        #expect(r.number == nil)
    }
}
