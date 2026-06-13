import SwiftUI
import SwiftData

/// Full-screen quotes list: LbHeader, rows (client · total · status badge · date),
/// EmptyArt, LbFloatingCTA "New quote". Tap a row -> editor; swipe -> soft-delete.
struct QuoteListView: View {
    let context: ModelContext
    let sync: any SyncEnqueuing
    let userId: String
    let profileId: String
    let onClose: () -> Void
    let onEdit: (String?) -> Void   // nil = new quote

    @Environment(\.accent) private var accent
    @State private var vm: QuoteListViewModel?

    var body: some View {
        ZStack(alignment: .bottom) {
            Palette.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                LbHeader(title: "Quotes", onClose: onClose, onAdd: { onEdit(nil) })
                if let vm {
                    if vm.quotes.isEmpty {
                        Spacer(); EmptyArt()
                        Text("No quotes yet").font(.ui(15)).foregroundStyle(Palette.ink3)
                            .padding(.top, 6)
                        Spacer()
                    } else {
                        List {
                            ForEach(vm.quotes) { quote in
                                Button { onEdit(quote.id) } label: { rowBody(quote) }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier(AccessibilityID.quoteRowPrefix + quote.id)
                                    .swipeActions {
                                        Button(role: .destructive) { vm.delete(quote) } label: { Text("Delete") }
                                    }
                            }
                            .listRowBackground(Palette.cream)
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                } else { Color.clear }
            }
            LbFloatingCTA(title: "New quote", a11yId: AccessibilityID.quotesAdd) { onEdit(nil) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.quotesScreen)
        .transition(.opacity)
        .task {
            vm = QuoteListViewModel(context: context, sync: sync, userId: userId, profileId: profileId)
        }
    }

    @ViewBuilder private func rowBody(_ quote: Quote) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(quote.clientName ?? "No client").font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                HStack(spacing: 6) {
                    // Only show the quote number when one exists; an un-numbered draft
                    // would otherwise read "Draft  Draft" (placeholder + status badge).
                    if let number = quote.number {
                        Text(number).font(.ui(11.5, .semibold)).foregroundStyle(Palette.ink3)
                    }
                    statusBadge(quote)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(fmt(quote.totalCents)).font(.ui(14, .semibold)).foregroundStyle(Palette.ink).monospacedDigit()
                Text(fmtDate(isoDay(quote.createdAt))).font(.ui(11.5)).foregroundStyle(Palette.ink3)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private func statusBadge(_ quote: Quote) -> some View {
        let label = quote.statusValue?.label ?? "Draft"
        let isSent = quote.statusValue == .sent || quote.statusValue == .accepted || quote.statusValue == .invoiced
        Text(label).font(.ui(10.5, .bold)).foregroundStyle(isSent ? Palette.income : Palette.ink3)
            .padding(.vertical, 2).padding(.horizontal, 8)
            .background((isSent ? Palette.income : Palette.ink3).opacity(0.14), in: Capsule())
    }

    /// Convert an epoch-ms createdAt into a "yyyy-MM-dd" string for `fmtDate`.
    private func isoDay(_ ms: Int) -> String {
        ExportDateFormatter.shared.string(from: Date(timeIntervalSince1970: Double(ms) / 1000.0))
    }
}
