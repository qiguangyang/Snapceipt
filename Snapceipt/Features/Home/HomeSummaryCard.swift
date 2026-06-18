import SwiftUI
import SwiftData

/// Home hero — the design's `SummaryCard`: a gradient "Net this month" card with a
/// mode pill and two income/expense tiles. Net / income / expense are computed live
/// from the active profile's transactions in the current calendar month.
struct HomeSummaryCard: View {
    @Environment(\.accent) private var accent
    @Query private var txns: [Transaction]
    private let isBusiness: Bool

    init(profileId: String, isBusiness: Bool) {
        self.isBusiness = isBusiness
        _txns = Query(filter: #Predicate<Transaction> { $0.profileId == profileId && $0.deletedAt == nil })
    }

    var body: some View {
        let s = monthSummary()
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Net this month · \(Self.monthName)")
                    .font(.ui(13, .semibold)).foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 8)
                Text(isBusiness ? "Business" : "Personal")
                    .font(.ui(12, .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.white.opacity(0.18), in: Capsule())
            }
            Text(Self.money(s.net, code: s.code))
                .numeric(40).foregroundStyle(.white)
                .padding(.top, 4)
            HStack(spacing: 10) {
                tile(icon: "arrowDown", label: "Income", cents: s.income, code: s.code)
                tile(icon: "arrowUp", label: "Expenses", cents: s.expense, code: s.code)
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .shadow(color: accent.base.opacity(0.45), radius: 13, x: 0, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.homeSummary)
    }

    private var cardBackground: some View {
        ZStack {
            LinearGradient(colors: [accent.base, accent.deep],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // Decorative translucent circles, clipped to the card.
            Circle().fill(.white.opacity(0.08)).frame(width: 150, height: 150)
                .offset(x: 150, y: -90)
            Circle().fill(.white.opacity(0.06)).frame(width: 120, height: 120)
                .offset(x: 110, y: 95)
        }
    }

    /// Net / income / expense (in cents) for the active profile this calendar month.
    private func monthSummary() -> (net: Int, income: Int, expense: Int, code: String) {
        let prefix = Self.monthPrefix
        let month = txns.filter { $0.txnDate.hasPrefix(prefix) }
        let income = month.filter { $0.amountCents > 0 }.reduce(0) { $0 + $1.amountCents }
        let expense = month.filter { $0.amountCents < 0 }.reduce(0) { $0 - $1.amountCents }
        return (income - expense, income, expense, txns.first?.currency ?? "AUD")
    }

    private func tile(icon: String, label: String, cents: Int, code: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Icon(name: icon, size: 15, color: .white)
                Text(label).font(.ui(12, .semibold)).foregroundStyle(.white.opacity(0.9))
            }
            Text(Self.money(cents, code: code)).numeric(18).foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Formatting / current month

    /// "$1,234" (no cents); negative renders with a leading minus.
    static func money(_ cents: Int, code: String) -> String {
        (Decimal(cents) / 100).formatted(.currency(code: code).precision(.fractionLength(0)))
    }

    private static var monthPrefix: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"; return f.string(from: Date())
    }
    private static var monthName: String {
        let f = DateFormatter(); f.dateFormat = "MMMM"; return f.string(from: Date())
    }
}
