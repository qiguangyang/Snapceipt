import Foundation
import SwiftData

/// Backs the Activity tab: the active profile's saved receipts, newest first.
/// (Receipts had no list surface before — Home is a dashboard, Reports is charts, and
/// the Activity tab was a stub, so a saved receipt appeared "lost".)
@Observable
@MainActor
final class ReceiptsListViewModel {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let profileId: String
    private(set) var rows: [ReceiptRow] = []

    init(context: ModelContext, profileId: String) {
        self.context = context
        self.profileId = profileId
        load()
    }

    /// Re-fetch from SwiftData. Called on appear so a just-saved receipt shows.
    func load() {
        let pid = profileId
        guard !pid.isEmpty else { rows = []; return }
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.txnDate, order: .reverse),
                     SortDescriptor(\.createdAt, order: .reverse)])
        rows = ((try? context.fetch(descriptor)) ?? []).map(ReceiptRow.init)
    }
}

/// Display row for one saved receipt.
struct ReceiptRow: Identifiable, Equatable {
    let id: String
    let merchant: String
    let amountCents: Int      // signed: expense < 0, income > 0
    let currency: String
    let txnDate: String       // "YYYY-MM-DD" — the receipt's printed date
    let createdDate: String   // "YYYY-MM-DD" — when the item was added (local)
    let createdAt: Int        // epoch ms — precise add time for sorting
    let category: CategoryKey?
    let isAi: Bool

    var isIncome: Bool { amountCents > 0 }

    init(_ t: Transaction) {
        id = t.id
        merchant = t.merchant.isEmpty ? "Receipt" : t.merchant
        amountCents = t.amountCents
        currency = t.currency.isEmpty ? "AUD" : t.currency
        txnDate = t.txnDate
        createdAt = t.createdAt
        createdDate = ReceiptRow.ymd(from: Date(timeIntervalSince1970: Double(t.createdAt) / 1000))
        category = CategoryKey(rawValue: t.catKey)
        isAi = t.isAi
    }

    /// Local "YYYY-MM-DD" for an added-on date.
    static func ymd(from date: Date) -> String { ymdFormatter.string(from: date) }
    private static let ymdFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    /// Localized amount, e.g. "$10.00" (sign is conveyed by colour/prefix in the row).
    var amountText: String {
        (Decimal(abs(amountCents)) / 100).formatted(.currency(code: currency))
    }

    /// "28 May 2026" (falls back to the raw string if unparseable).
    var dateText: String {
        guard let date = Self.iso.date(from: txnDate) else { return txnDate }
        return Self.display.string(from: date)
    }

    private static let iso: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let display: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy"; return f
    }()
}
