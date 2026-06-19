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
    @Environment(EntitlementStore.self) private var entitlement
    @State private var vm: QuoteListViewModel?
    @State private var showPaywall = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Palette.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                LbHeader(title: "Quotes", onClose: onClose, onAdd: {
                    guard entitlement.isPro else { showPaywall = true; return }
                    onEdit(nil)
                })
                if let vm {
                    if vm.quotes.isEmpty {
                        Spacer(); EmptyArt()
                        Text("No quotes yet").font(.ui(15)).foregroundStyle(Palette.ink3)
                            .padding(.top, 6)
                        Spacer()
                    } else {
                        List {
                            ForEach(vm.quotes) { quote in
                                Button {
                                    guard entitlement.isPro else { showPaywall = true; return }
                                    onEdit(quote.id)
                                } label: { rowBody(quote) }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier(AccessibilityID.quoteRowPrefix + quote.id)
                                    .listRowBackground(Palette.cream)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 5, leading: 18, bottom: 5, trailing: 18))
                                    .swipeActions(allowsFullSwipe: false) {
                                        Button(role: .destructive) { vm.delete(quote) } label: {
                                            Image(systemName: "trash")
                                        }
                                        .accessibilityIdentifier(AccessibilityID.quoteRowDelete + quote.id)
                                        Button {
                                            guard entitlement.isPro else { showPaywall = true; return }
                                            if let newId = vm.duplicate(quote) { onEdit(newId) }
                                        } label: {
                                            Image(systemName: "plus.square.on.square")
                                        }
                                        .tint(accent.base)
                                        .accessibilityIdentifier(AccessibilityID.quoteRowDuplicate + quote.id)
                                    }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                } else { Color.clear }
            }
            LbFloatingCTA(title: "New quote", a11yId: AccessibilityID.quotesAdd) {
                guard entitlement.isPro else { showPaywall = true; return }
                onEdit(nil)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.quotesScreen)
        .transition(.opacity)
        .task {
            vm = QuoteListViewModel(context: context, sync: sync, userId: userId, profileId: profileId)
            if !entitlement.isPro { showPaywall = true }
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
    }

    @ViewBuilder private func rowBody(_ quote: Quote) -> some View {
        Card(padding: 14) {
            HStack(spacing: 12) {
                clientTile(quote.clientName)
                VStack(alignment: .leading, spacing: 4) {
                    Text(quote.clientName ?? "No client").font(.ui(14.5, .bold)).foregroundStyle(Palette.ink)
                    HStack(spacing: 6) {
                        // Only show the quote number when one exists; an un-numbered draft
                        // would otherwise read "Draft  Draft" (placeholder + status badge).
                        if let number = quote.number {
                            Text(number).font(.ui(11.5, .semibold)).foregroundStyle(Palette.ink3)
                        }
                        statusBadge(quote)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(fmt(quote.totalCents)).font(.ui(15, .bold)).foregroundStyle(Palette.ink).monospacedDigit()
                    Text(fmtDate(isoDay(quote.createdAt))).font(.ui(11.5)).foregroundStyle(Palette.ink3)
                }
            }
            .contentShape(Rectangle())
        }
    }

    /// 42×42 accent-soft tile: client initials, or a building glyph for an un-named draft.
    @ViewBuilder private func clientTile(_ name: String?) -> some View {
        if let name, let initial = name.trimmingCharacters(in: .whitespaces).first {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(accent.soft)
                .frame(width: 42, height: 42)
                .overlay(Text(String(initial).uppercased()).font(.ui(16, .bold)).foregroundStyle(accent.base))
        } else {
            IconCircle(name: "building", tint: accent.base, soft: accent.soft, size: 42, iconSize: 19)
        }
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
