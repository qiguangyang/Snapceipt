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
}
