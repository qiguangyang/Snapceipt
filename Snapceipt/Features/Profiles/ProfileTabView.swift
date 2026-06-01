import SwiftUI

/// The Settings hub (F7): identity header, profile-switcher grid, grouped setting
/// rows (Capture & tax / App / Account), and sign-out. Navigation is delegated to
/// closures supplied by `RootView`; profile state comes from `ProfilesStore`.
struct ProfileTabView: View {
    let profiles: ProfilesStore
    let userName: String
    let userEmail: String?
    let onOpenNotifications: () -> Void
    let onOpenBudgets: () -> Void
    let onOpenEmailIn: () -> Void
    let onOpenTax: () -> Void
    let onOpenCategories: () -> Void
    let onOpenExport: () -> Void
    let onOpenPrivacy: () -> Void
    let onOpenAccount: () -> Void
    let onOpenProfileDetail: (String) -> Void
    let onAddProfile: () -> Void
    let onSignOut: () -> Void

    @Environment(\.accent) private var accent

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("Profile").font(.display(28)).foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Identity header (data-bound; no hardcoded name).
                Card(padding: 14) {
                    HStack(spacing: 12) {
                        IconCircle(name: "user", tint: accent.base, soft: accent.soft, size: 44, iconSize: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(userName).font(.ui(16, .semibold)).foregroundStyle(Palette.ink)
                            if let e = userEmail { Text(e).font(.ui(13)).foregroundStyle(Palette.ink3) }
                        }
                        Spacer()
                    }
                }

                // Profile switcher grid.
                profileSwitcher

                groupLabel("Capture & tax")
                row(icon: "receipt", title: "Categories & rules", id: AccessibilityID.profileRowCategories, action: onOpenCategories)
                row(icon: "gear", title: "Tax & GST settings", id: AccessibilityID.profileRowTax, action: onOpenTax)

                groupLabel("App")
                row(icon: "bell", title: "Notifications & alerts", id: AccessibilityID.profileRowNotifications, action: onOpenNotifications)
                row(icon: "wallet", title: "Budgets", id: AccessibilityID.profileRowBudgets, action: onOpenBudgets)
                row(icon: "receipt", title: "Email-in receipts", id: AccessibilityID.profileRowEmailIn, action: onOpenEmailIn)
                row(icon: "arrowRight", title: "Export & backup", id: "profile.row.export", action: onOpenExport)
                row(icon: "info", title: "Privacy & security", id: AccessibilityID.profileRowPrivacy, action: onOpenPrivacy)

                groupLabel("Account")
                row(icon: "user", title: "Account", id: AccessibilityID.profileRowAccount, action: onOpenAccount)

                Button(action: onSignOut) {
                    Text("Sign out").font(.ui(15, .semibold)).foregroundStyle(Palette.alert)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.signOutButton)
                .padding(.top, 8)
            }
            .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 110)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.profileHubScreen)
    }

    private var profileSwitcher: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(profiles.profiles, id: \.id) { p in
                Button { onOpenProfileDetail(p.id) } label: {
                    Card(padding: 12) {
                        HStack(spacing: 10) {
                            IconCircle(name: p.type == "business" ? "building" : "wallet", tint: accent.base, soft: accent.soft, size: 32, iconSize: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name).font(.ui(13.5, .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                                Text(p.id == profiles.activeProfileId ? "Active" : p.type.capitalized)
                                    .font(.ui(11.5)).foregroundStyle(p.id == profiles.activeProfileId ? accent.base : Palette.ink3)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.profileSwitcherCardPrefix + p.id)
            }
            Button(action: onAddProfile) {
                Card(padding: 12) {
                    HStack(spacing: 8) {
                        Icon(name: "plus", size: 16, color: accent.base, lineWidth: 2.2)
                        Text("Add profile").font(.ui(13.5, .semibold)).foregroundStyle(accent.base)
                        Spacer(minLength: 0)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.profileAddButton)
        }
    }

    private func groupLabel(_ s: String) -> some View {
        Text(s).font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
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
