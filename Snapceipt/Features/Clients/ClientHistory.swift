import Foundation
import SwiftData

/// History is an explicit association query; contact snapshots never establish membership.
enum ClientHistory {
    enum DocumentKind: String, Hashable {
        case quote, invoice
    }

    struct DocumentReference: Hashable {
        let kind: DocumentKind
        let id: String
    }

    struct Document: Identifiable {
        let kind: DocumentKind
        let id: String
        let number: String?
        let createdAt: Int
        let totalCents: Int
        let status: String
        let paymentState: AccountsReceivable.PaymentState?
        var reference: DocumentReference { .init(kind: kind, id: id) }
    }

    struct Snapshot {
        let documents: [Document]
        let outstandingCents: Int
    }

    @MainActor
    static func load(context: ModelContext, userId: String, profileId: String,
                     clientId: String, today: String) throws -> Snapshot {
        let quotes = try context.fetch(FetchDescriptor<Quote>(predicate: #Predicate {
            $0.userId == userId && $0.profileId == profileId && $0.clientId == clientId && $0.deletedAt == nil
        }))
        let invoices = try context.fetch(FetchDescriptor<Invoice>(predicate: #Predicate {
            $0.userId == userId && $0.profileId == profileId && $0.clientId == clientId && $0.deletedAt == nil
        }))
        // Payments are invoice children with no independent profile. Scope through the invoice
        // and authenticated user before giving them to the existing receivables derivation.
        let payments = try context.fetch(FetchDescriptor<Payment>(predicate: #Predicate {
            $0.userId == userId && $0.deletedAt == nil
        }))
        let byInvoice = Dictionary(grouping: payments, by: \.invoiceId)
        var outstanding = 0
        var documents = quotes.map {
            Document(kind: .quote, id: $0.id, number: $0.number, createdAt: $0.createdAt,
                     totalCents: $0.totalCents, status: $0.status, paymentState: nil)
        }
        for invoice in invoices {
            let derived = AccountsReceivable.derive(invoice: invoice, payments: byInvoice[invoice.id] ?? [], today: today)
            if invoice.status == "issued" {
                outstanding += max(invoice.totalCents - derived.amountPaidCents, 0)
            }
            documents.append(Document(kind: .invoice, id: invoice.id, number: invoice.number,
                                      createdAt: invoice.createdAt, totalCents: invoice.totalCents,
                                      status: invoice.status, paymentState: derived.paymentState))
        }
        documents.sort {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.id < $1.id
        }
        return Snapshot(documents: documents, outstandingCents: outstanding)
    }
}
