import Foundation

/// The six quote lifecycle states. Raw values are the exact strings stored in
/// `Quote.status` (and validated by the D1 CHECK server-side). `accepted`/`invoiced`
/// are modeled for the post-v1 invoice flow but unused by the v1 UI.
enum QuoteStatus: String, CaseIterable, Sendable {
    case draft
    case sent
    case accepted
    case declined
    case expired
    case invoiced

    /// Short label for the list status badge.
    var label: String {
        switch self {
        case .draft: return "Draft"
        case .sent: return "Sent"
        case .accepted: return "Accepted"
        case .declined: return "Declined"
        case .expired: return "Expired"
        case .invoiced: return "Invoiced"
        }
    }
}

extension Quote {
    /// Typed view over the raw `status` storage. Storage stays `String` for sync
    /// symmetry; this only bridges read/write to the enum (nil for an unknown value).
    var statusValue: QuoteStatus? {
        get { QuoteStatus(rawValue: status) }
        set { if let newValue { status = newValue.rawValue } }
    }
}
