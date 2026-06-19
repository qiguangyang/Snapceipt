import SwiftUI
import SwiftData

/// Full-screen invoices list: LbHeader, a "Needs attention" section (overdue/due-soon,
/// soft amber), then the rest. Rows = client · total · A/R badge · due date. Tap a row →
/// editor; swipe → soft-delete. Pro-gated like Quotes. Mirrors `QuoteListView`.
///
/// Soft framing (spec): the amber accent + the "Needs attention" grouping are driven by
/// `Row.attention` (`.overdue`/`.dueSoon`), NEVER by `badge` (the payment state, which has
/// no overdue case). Overdue uses `Palette.warn` (soft amber), never `Palette.alert` red.
struct InvoiceListView: View {
    let context: ModelContext
    let sync: any SyncEnqueuing
    let userId: String
    let profileId: String
    let onClose: () -> Void
    let onEdit: (String?) -> Void   // nil = new invoice

    @Environment(\.accent) private var accent
    @Environment(EntitlementStore.self) private var entitlement
    @State private var vm: InvoiceListViewModel?
    @State private var showPaywall = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Palette.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                LbHeader(title: "Invoices", onClose: onClose, onAdd: {
                    guard entitlement.isPro else { showPaywall = true; return }
                    onEdit(nil)
                })
                if let vm {
                    if vm.needsAttention.isEmpty && vm.others.isEmpty {
                        Spacer(); EmptyArt()
                        Text("No invoices yet").font(.ui(15)).foregroundStyle(Palette.ink3).padding(.top, 6)
                        Spacer()
                    } else {
                        List {
                            if !vm.needsAttention.isEmpty {
                                Section {
                                    ForEach(vm.needsAttention) { row in rowButton(vm, row) }
                                } header: {
                                    Text("Needs attention").font(.ui(12.5, .bold)).foregroundStyle(Palette.warn)
                                        .accessibilityIdentifier(AccessibilityID.invoiceNeedsAttentionSection)
                                }
                                .listRowBackground(Palette.cream)
                            }
                            if !vm.others.isEmpty {
                                Section {
                                    ForEach(vm.others) { row in rowButton(vm, row) }
                                }
                                .listRowBackground(Palette.cream)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                } else { Color.clear }
            }
            LbFloatingCTA(title: "New invoice", a11yId: AccessibilityID.invoicesAdd) {
                guard entitlement.isPro else { showPaywall = true; return }
                onEdit(nil)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.invoicesScreen)
        .transition(.opacity)
        .task {
            vm = InvoiceListViewModel(context: context, sync: sync, userId: userId, profileId: profileId)
            if !entitlement.isPro { showPaywall = true }
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
    }

    @ViewBuilder private func rowButton(_ vm: InvoiceListViewModel, _ row: InvoiceListViewModel.Row) -> some View {
        Button {
            guard entitlement.isPro else { showPaywall = true; return }
            onEdit(row.invoice.id)
        } label: { rowBody(row) }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.invoiceRowPrefix + row.invoice.id)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 5, leading: 18, bottom: 5, trailing: 18))
            .swipeActions {
                Button(role: .destructive) { vm.delete(row.invoice) } label: { Text("Delete") }
            }
    }

    @ViewBuilder private func rowBody(_ row: InvoiceListViewModel.Row) -> some View {
        let inv = row.invoice
        let overdue = row.attention == .overdue
        Card(padding: 14) {
            HStack(spacing: 12) {
                clientTile(inv.clientName)
                VStack(alignment: .leading, spacing: 4) {
                    Text(inv.clientName ?? "No client").font(.ui(14.5, .bold)).foregroundStyle(Palette.ink)
                    HStack(spacing: 6) {
                        if let number = inv.number {
                            Text(number).font(.ui(11.5, .semibold)).foregroundStyle(Palette.ink3)
                        }
                        badgeView(row)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(fmt(inv.totalCents)).font(.ui(15, .bold)).foregroundStyle(Palette.ink).monospacedDigit()
                    if let due = inv.dueDate {
                        // Overdue tints the due date amber (soft framing); never red.
                        Text("Due \(fmtDate(due))").font(.ui(11.5))
                            .foregroundStyle(overdue ? Palette.warn : Palette.ink3)
                    }
                }
            }
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder private func clientTile(_ name: String?) -> some View {
        if let name, let initial = name.trimmingCharacters(in: .whitespaces).first {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(accent.soft).frame(width: 42, height: 42)
                .overlay(Text(String(initial).uppercased()).font(.ui(16, .bold)).foregroundStyle(accent.base))
        } else {
            IconCircle(name: "building", tint: accent.base, soft: accent.soft, size: 42, iconSize: 19)
        }
    }

    /// Payment-state badge (Unpaid/Partial/Paid from `badge`) plus a soft-amber attention
    /// overlay (Overdue/Due soon) driven by `row.attention` — never `Palette.alert` red.
    @ViewBuilder private func badgeView(_ row: InvoiceListViewModel.Row) -> some View {
        pill(text: paymentLabel(row.badge), color: paymentColor(row.badge))
        switch row.attention {
        case .overdue: pill(text: "Overdue", color: Palette.warn)
        case .dueSoon: pill(text: "Due soon", color: Palette.warn)
        case nil: EmptyView()
        }
    }

    @ViewBuilder private func pill(text: String, color: Color) -> some View {
        Text(text).font(.ui(10.5, .bold)).foregroundStyle(color)
            .padding(.vertical, 2).padding(.horizontal, 8)
            .background(color.opacity(0.14), in: Capsule())
    }

    /// Capitalised payment-state label for the A/R badge.
    private func paymentLabel(_ badge: InvoiceBadge) -> String {
        switch badge {
        case .unpaid: return "Unpaid"
        case .partial: return "Partial"
        case .paid: return "Paid"
        }
    }

    /// Paid = income green; otherwise neutral ink-3. (Overdue/due-soon amber comes from
    /// the separate attention pill, not the payment-state badge.)
    private func paymentColor(_ badge: InvoiceBadge) -> Color {
        badge == .paid ? Palette.income : Palette.ink3
    }
}
