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
                            ForEach(Array(vm.items.enumerated()), id: \.element.id) { index, item in
                                Button { vm.markRead(item.id); onOpenBudget(item.budgetId); onClose() } label: { row(item, index: index, read: vm.isRead(item.id)) }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier(AccessibilityID.alertRowPrefix + item.id)
                                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                                    .listRowSeparator(.hidden)
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

    /// Per-alert-type icon + tint/soft. `AlertFeed.Item` carries no kind/type, so we
    /// vary by index across the design's set (shield/sparkles/film/wallet). `shield`
    /// and `film` aren't in the icon set, so we use the closest existing glyphs
    /// (`info`, `clock`) while keeping the specified tints.
    private func style(for index: Int) -> (name: String, tint: Color, soft: Color, filled: Bool) {
        switch index % 4 {
        case 0:  return ("info",     Palette.income,        Palette.incomeSoft,    false)
        case 1:  return ("sparkles", accent.base,           accent.soft,           true)
        case 2:  return ("clock",    Color(hex: 0x7B5BD6),  Color(hex: 0xEBE5F8),  false)
        default: return ("wallet",   accent.base,           accent.soft,           false)
        }
    }

    private func row(_ item: AlertFeed.Item, index: Int, read: Bool) -> some View {
        let s = style(for: index)
        return Card(padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                IconCircle(name: s.name, tint: s.tint, soft: s.soft, size: 40, iconSize: 20, filled: s.filled)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.title).font(.ui(14.5, .bold)).foregroundStyle(Palette.ink)
                        Spacer(minLength: 0)
                        Text(relativeTime(item.firedAt)).font(.ui(11.5)).foregroundStyle(Palette.ink3)
                    }
                    Text(item.body).font(.ui(13)).foregroundStyle(Palette.ink2).monospacedDigit()
                }
                if !read { Circle().fill(accent.base).frame(width: 8, height: 8).padding(.top, 4) }
            }
        }
    }

    private func relativeTime(_ ms: Int) -> String {
        let fired = Date(timeIntervalSince1970: Double(ms) / 1000.0)
        let now = Epoch.now()
        // A just-fired alert (firedAt at/after now) would otherwise render as the
        // future-tense "in 0 seconds"; clamp to a sensible past-tense label.
        if fired >= now { return "Just now" }
        let f = RelativeDateTimeFormatter()
        return f.localizedString(for: fired, relativeTo: now)
    }
}
