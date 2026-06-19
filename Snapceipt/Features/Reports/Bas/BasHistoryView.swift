import SwiftUI

/// "Past BAS" history list (spec 2026-06-19). One row per period (most-recent first),
/// each showing its net-GST headline + a soft status badge. Tap → `onSelect(offset)`
/// moves the BasView cursor to that period. Presented as a sheet from BasView.
struct BasHistoryView: View {
    let rows: [BasHistory.Row]
    let currentOffset: Int
    let onSelect: (Int) -> Void
    let onClose: () -> Void

    @Environment(\.accent) private var accent

    var body: some View {
        ZStack {
            Palette.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                SheetHeader(title: "Past BAS", onClose: onClose)
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(rows) { row in
                            Button { onSelect(row.offset) } label: { rowBody(row) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(AccessibilityID.basHistoryRowPrefix + row.periodKey)
                        }
                    }
                    .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 60)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.basHistoryScreen)
        .transition(.opacity)
    }

    @ViewBuilder private func rowBody(_ row: BasHistory.Row) -> some View {
        Card {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(row.label).font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                        if row.offset == currentOffset {
                            Text("Current").font(.ui(11, .semibold)).foregroundStyle(accent.base)
                        }
                    }
                    statusLabel(row.status)
                }
                Spacer()
                Text(netLabel(row.netGstCents)).font(.ui(14, .semibold))
                    .foregroundStyle(Palette.ink).monospacedDigit()
            }
        }
    }

    private func netLabel(_ cents: Int) -> String {
        cents < 0 ? "Refund \(fmt(-cents))" : "\(fmt(cents))"
    }

    @ViewBuilder private func statusLabel(_ status: BasHistory.Status) -> some View {
        switch status {
        case let .lodged(atMs, drifted):
            Text(drifted
                 ? "Lodged \(fmtBasDue(Date(timeIntervalSince1970: Double(atMs) / 1000))) · figures changed"
                 : "Lodged \(fmtBasDue(Date(timeIntervalSince1970: Double(atMs) / 1000)))")
                .font(.ui(12)).foregroundStyle(accent.base)
        case let .due(date):
            Text("Due \(fmtBasDue(date))").font(.ui(12)).foregroundStyle(Palette.ink3)
        case let .notMarkedLodged(date):
            Text("Not marked as lodged · was due \(fmtBasDue(date))")
                .font(.ui(12, .semibold)).foregroundStyle(Palette.warn)
        }
    }
}
