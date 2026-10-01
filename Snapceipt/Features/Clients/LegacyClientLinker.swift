import Foundation

/// Exact matches are suggestions only. This helper neither persists nor associates documents.
enum LegacyClientLinker {
    enum Reason: String, Equatable {
        case email, name
    }

    struct Suggestion: Equatable {
        let kind: ClientHistory.DocumentKind
        let documentId: String
        let reason: Reason
        var reference: ClientHistory.DocumentReference { .init(kind: kind, id: documentId) }
    }

    static func suggestions(client: ClientSelection, userId: String, profileId: String,
                            quotes: [Quote], invoices: [Invoice]) -> [Suggestion] {
        let email = normalizeEmail(client.email)
        let name = normalizeName(client.name)
        func reason(_ originalName: String?, _ originalEmail: String?) -> Reason? {
            if !email.isEmpty && email == normalizeEmail(originalEmail) { return .email }
            if !name.isEmpty && name == normalizeName(originalName) { return .name }
            return nil
        }
        var matches: [Suggestion] = []
        for quote in quotes where quote.userId == userId && quote.profileId == profileId && quote.deletedAt == nil && quote.clientId == nil {
            if let why = reason(quote.clientName, quote.clientEmail) {
                matches.append(Suggestion(kind: .quote, documentId: quote.id, reason: why))
            }
        }
        for invoice in invoices where invoice.userId == userId && invoice.profileId == profileId && invoice.deletedAt == nil && invoice.clientId == nil {
            if let why = reason(invoice.clientName, invoice.clientEmail) {
                matches.append(Suggestion(kind: .invoice, documentId: invoice.id, reason: why))
            }
        }
        return matches.sorted {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.documentId < $1.documentId
        }
    }

    private static func normalizeEmail(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func normalizeName(_ value: String?) -> String {
        (value ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }
}
