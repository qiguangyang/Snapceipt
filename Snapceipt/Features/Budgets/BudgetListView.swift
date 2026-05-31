import SwiftUI
import SwiftData

/// Full-screen budgets list: rows (label, scope, spent/cap bar, threshold%), Add CTA,
/// tap -> editor, swipe -> soft-delete, empty state.
struct BudgetListView: View {
    let context: ModelContext
    let sync: any SyncEnqueuing
    let userId: String
    let profileId: String
    let onClose: () -> Void
    let onEdit: (String?) -> Void   // nil = add

    @Environment(\.accent) private var accent
    @State private var vm: BudgetListViewModel?

    var body: some View {
        ZStack(alignment: .bottom) {
            Palette.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                LbHeader(title: "Budgets", onClose: onClose, onAdd: { onEdit(nil) })
                if let vm {
                    if vm.budgets.isEmpty {
                        Spacer(); EmptyArt(); Text("No budgets yet").font(.ui(15)).foregroundStyle(Palette.ink3); Spacer()
                    } else {
                        List {
                            ForEach(vm.rows()) { row in
                                Button { onEdit(row.budget.id) } label: { rowBody(row) }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier(AccessibilityID.budgetRowPrefix + row.budget.id)
                                    .swipeActions {
                                        Button(role: .destructive) { vm.delete(row.budget) } label: { Text("Delete") }
                                    }
                            }
                            .listRowBackground(Palette.cream)
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                } else { Color.clear }
            }
            LbFloatingCTA(title: "Add a budget", a11yId: AccessibilityID.budgetListAdd) { onEdit(nil) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.budgetListScreen)
        .transition(.opacity)
        .task {
            // Rebuild each appear so an edit/add reflects on return.
            vm = BudgetListViewModel(context: context, sync: sync, userId: userId, profileId: profileId)
        }
    }

    @ViewBuilder private func rowBody(_ row: BudgetListViewModel.Row) -> some View {
        let over = row.overCap
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.budget.label).font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                Spacer()
                Text("\(fmt(row.spentCents)) / \(fmt(row.budget.capCents))")
                    .font(.ui(13, .semibold)).foregroundStyle(over ? Palette.alert : Palette.ink2).monospacedDigit()
            }
            ProgressBar(value: Double(row.spentCents),
                        max: Double(Swift.max(1, row.budget.capCents)),
                        tint: over ? Palette.alert : accent.base)
            Text("\(row.budget.categoryId == nil ? "Whole profile" : (row.budget.label)) · alert \(row.budget.alertThresholdPct)%")
                .font(.ui(11.5)).foregroundStyle(Palette.ink3)
        }
        .padding(.vertical, 6)
    }
}
