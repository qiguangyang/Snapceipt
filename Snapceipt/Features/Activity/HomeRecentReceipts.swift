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
                    ForEach(rows) { row in
                        Button { onOpenReceipt(row.id) } label: {
                            ReceiptRowView(row: row)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .accessibilityIdentifier(AccessibilityID.homeRecentSection)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Recent receipts").font(.ui(16, .bold)).foregroundStyle(Palette.ink)
            Spacer()
            Button(action: onSeeAll) {
                Text("See all").font(.ui(13, .semibold)).foregroundStyle(accent.base)
            }
            .accessibilityIdentifier(AccessibilityID.homeRecentSeeAll)
        }
    }
}
