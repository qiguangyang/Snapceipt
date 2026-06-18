import SwiftUI
import SwiftData

/// "Recent receipts" section for the Home dashboard. Uses `@Query` (not appear-reload)
/// because Home stays visible during capture, so it must refresh the instant a receipt
/// is saved. Shows the latest few; "See all" jumps to the Activity tab. Hidden when empty.
struct HomeRecentReceipts: View {
    @Environment(\.accent) private var accent
    @Query private var txns: [Transaction]
    private let onSeeAll: () -> Void
    private let onOpenReceipt: (String) -> Void

    init(profileId: String, onSeeAll: @escaping () -> Void, onOpenReceipt: @escaping (String) -> Void) {
        self.onSeeAll = onSeeAll
        self.onOpenReceipt = onOpenReceipt
        _txns = Query(filter: #Predicate<Transaction> { $0.profileId == profileId && $0.deletedAt == nil },
                      sort: \.txnDate, order: .reverse)
    }

    var body: some View {
        let rows = txns.prefix(4).map { ReceiptRow($0) }
        return Group {
            if !rows.isEmpty {
                VStack(spacing: 10) {
                    header
                    card(rows)
                }
                .accessibilityIdentifier(AccessibilityID.homeRecentSection)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Recent activity").font(.ui(17, .bold)).foregroundStyle(Palette.ink).tracking(-0.3)
            Spacer()
            Button(action: onSeeAll) {
                HStack(spacing: 2) {
                    Text("See all").font(.ui(13, .semibold)).foregroundStyle(accent.base)
                    Icon(name: "chevR", size: 15, color: accent.base)
                }
            }
            .accessibilityIdentifier(AccessibilityID.homeRecentSeeAll)
        }
        .padding(.horizontal, 2)
    }

    private func card(_ rows: [ReceiptRow]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                Button { onOpenReceipt(row.id) } label: {
                    ReceiptRowView(row: row, showDivider: idx < rows.count - 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        // Non-hit-testing so the decorative border doesn't swallow the row buttons' taps.
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.line2, lineWidth: 1).allowsHitTesting(false))
        .cardShadow()
    }
}
