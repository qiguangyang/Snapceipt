import SwiftUI
import SwiftData

/// Home budget tracker card: the active profile's top-3 monthly budgets, each a
/// BudgetRow (label, spent/cap via fmt, ProgressBar tinted accent -> --alert red over
/// cap). Edit link -> BudgetListView; tap a row -> that budget's editor; empty-state CTA.
struct BudgetTrackerView: View {
    let context: ModelContext
    let sync: any SyncEnqueuing
    let userId: String
    let profileId: String
    let onEdit: () -> Void
    let onTapBudget: (String) -> Void
    let onAdd: () -> Void

    @Environment(\.accent) private var accent
    @State private var vm: BudgetListViewModel?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Monthly budgets").font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
                    Spacer()
                    if let vm, !vm.budgets.isEmpty {
                        Button(action: onEdit) {
                            Text("Edit").font(.ui(13.5, .semibold)).foregroundStyle(accent.base)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(AccessibilityID.homeBudgetEditLink)
                    }
                }
                if let vm, !vm.budgets.isEmpty {
                    ForEach(vm.top3()) { row in
                        Button { onTapBudget(row.budget.id) } label: { rowBody(row) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(AccessibilityID.budgetRowPrefix + row.budget.id)
                    }
                } else {
                    emptyState
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.homeBudgetTracker)
        .task {
            if vm == nil {
                vm = BudgetListViewModel(context: context, sync: sync,
                                         userId: userId, profileId: profileId)
            }
        }
    }

    @ViewBuilder private func rowBody(_ row: BudgetListViewModel.Row) -> some View {
        let over = row.overCap
        let tint = over ? Palette.alert : accent.base
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.budget.label).font(.ui(14)).foregroundStyle(Palette.ink)
                Spacer()
                Text("\(fmt(row.spentCents)) / \(fmt(row.budget.capCents))")
                    .font(.ui(13, .semibold)).foregroundStyle(over ? Palette.alert : Palette.ink2)
                    .monospacedDigit()
            }
            ProgressBar(value: Double(row.spentCents), max: Double(Swift.max(1, row.budget.capCents)), tint: tint)
        }
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("No budgets yet").font(.ui(14, .semibold)).foregroundStyle(Palette.ink2)
            Button(action: onAdd) {
                Text("Add a budget").font(.ui(14, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(accent.base, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.homeBudgetEmptyCTA)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
