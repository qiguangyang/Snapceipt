import SwiftUI

/// One saved-receipt row — category icon, merchant, date · category, and amount.
/// Shared by the Activity tab and the Home "Recent receipts" section.
struct ReceiptRowView: View {
    let row: ReceiptRow
    @Environment(\.accent) private var accent

    var body: some View {
        let meta = row.category.flatMap { CATS[$0] }
        HStack(spacing: 12) {
            IconCircle(name: meta?.iconName ?? "receipt",
                       tint: meta?.tint ?? accent.base,
                       soft: meta?.soft ?? accent.soft, size: 42, iconSize: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.merchant).font(.ui(15, .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                Text(meta.map { "\(row.dateText) · \($0.label)" } ?? row.dateText)
                    .font(.ui(12.5)).foregroundStyle(Palette.ink3).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(row.isIncome ? "+\(row.amountText)" : row.amountText)
                .font(.ui(15, .semibold)).monospacedDigit()
                .foregroundStyle(row.isIncome ? Palette.income : Palette.ink)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line, lineWidth: 1))
    }
}
