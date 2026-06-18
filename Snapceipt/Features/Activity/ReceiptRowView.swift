import SwiftUI

/// One saved-receipt row (the design's `TxnRow`) — category icon, merchant, a
/// "date · AI" subtitle, and a signed amount. Borderless: the containing card (Home
/// "Recent activity", the Activity day groups) supplies the paper chrome + hairline
/// dividers. Shared by the Activity tab and the Home recent section.
struct ReceiptRowView: View {
    let row: ReceiptRow
    var showDivider: Bool = false
    @Environment(\.accent) private var accent

    var body: some View {
        let meta = row.category.flatMap { CATS[$0] }
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconCircle(name: meta?.iconName ?? "receipt",
                           tint: meta?.tint ?? accent.base,
                           soft: meta?.soft ?? accent.soft, size: 42, iconSize: 20,
                           filled: row.category == .income)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.merchant).font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(row.dateText).font(.ui(12.5)).foregroundStyle(Palette.ink3)
                        if row.isAi {
                            HStack(spacing: 3) {
                                Icon(name: "sparkles", size: 11, color: accent.base, filled: true)
                                Text("AI").font(.ui(12.5, .semibold)).foregroundStyle(accent.base)
                            }
                        }
                    }
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(row.isIncome ? "+\(row.amountText)" : row.amountText)
                    .font(.ui(15, .bold)).monospacedDigit()
                    .foregroundStyle(row.isIncome ? Palette.income : Palette.ink)
            }
            .padding(.vertical, 12).padding(.horizontal, 2)
            if showDivider { Divider().overlay(Palette.line2) }
        }
    }
}
