import SwiftUI

/// Lightweight Profile tab — the F3 entry rows only ("Notifications & alerts",
/// "Budgets"). The full Profile/Settings hub is F7.
struct ProfileTabView: View {
    let onOpenNotifications: () -> Void
    let onOpenBudgets: () -> Void

    @Environment(\.accent) private var accent

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("Profile").font(.display(28)).foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                row(icon: "bell", title: "Notifications & alerts",
                    id: AccessibilityID.profileRowNotifications, action: onOpenNotifications)
                row(icon: "wallet", title: "Budgets",
                    id: AccessibilityID.profileRowBudgets, action: onOpenBudgets)
            }
            .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 110)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream)
    }

    private func row(icon: String, title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Card(padding: 14) {
                HStack(spacing: 12) {
                    IconCircle(name: icon, tint: accent.base, soft: accent.soft, size: 38, iconSize: 19)
                    Text(title).font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                    Spacer(); Icon(name: "chevR", size: 16, color: Palette.ink3)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}
