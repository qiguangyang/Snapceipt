import SwiftUI
import SwiftData

/// Full-screen alerts feed: IconCircle + title + relative time + body; tap -> mark read
/// + deep-link to the budget; swipe -> dismiss; EmptyArt empty state. Budget-alerts only.
struct AlertsSheet: View {
    let context: ModelContext
    let sync: any SyncEnqueuing
    let userId: String
    let profileId: String
    let onOpenBudget: (String) -> Void
    let onClose: () -> Void

    @Environment(\.accent) private var accent
    @State private var vm: AlertsViewModel?

    var body: some View {
        ZStack(alignment: .bottom) {
            Palette.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                SheetHeader(title: "Alerts", onClose: onClose)
                if let vm {
                    if vm.items.isEmpty {
                        Spacer(); EmptyArt(); Text("No alerts").font(.ui(15)).foregroundStyle(Palette.ink3); Spacer()
                    } else {
                        List {
                            ForEach(vm.items) { item in
                                Button { vm.markRead(item.id); onOpenBudget(item.budgetId); onClose() } label: { row(item, read: vm.isRead(item.id)) }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier(AccessibilityID.alertRowPrefix + item.id)
                                    .swipeActions {
                                        Button(role: .destructive) { vm.dismiss(item.id) } label: { Text("Dismiss") }
                                    }
                            }
                            .listRowBackground(Palette.cream)
                        }
                        .listStyle(.plain).scrollContentBackground(.hidden)
                    }
                } else { Color.clear }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.alertsScreen)
        .transition(.opacity)
        .task { vm = AlertsViewModel(context: context, userId: userId, profileId: profileId) }
    }

    private func row(_ item: AlertFeed.Item, read: Bool) -> some View {
        HStack(spacing: 12) {
            IconCircle(name: "bell", tint: accent.base, soft: accent.soft, size: 40, iconSize: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                Text(item.body).font(.ui(12.5)).foregroundStyle(Palette.ink3).monospacedDigit()
                Text(relativeTime(item.firedAt)).font(.ui(11)).foregroundStyle(Palette.ink3)
            }
            Spacer(minLength: 0)
            if !read { Circle().fill(accent.base).frame(width: 8, height: 8) }
        }
        .padding(.vertical, 6)
    }

    private func relativeTime(_ ms: Int) -> String {
        let f = RelativeDateTimeFormatter()
        return f.localizedString(for: Date(timeIntervalSince1970: Double(ms) / 1000.0), relativeTo: Date())
    }
}
