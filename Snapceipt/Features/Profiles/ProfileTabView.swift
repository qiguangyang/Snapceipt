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
    @Environment(\.openURL) private var openURL

    /// Inert visual toggle (matches the prototype): defaults ON, drives no behaviour.
    @State private var aiAutoCategorise = true

    /// Persisted Smart Scan AI toggle (default ON). Controls whether a scan calls
    /// DeepSeek (`/extract`) or uses the on-device heuristic — see CaptureViewModel.extract().
    @AppStorage(AppSettings.smartScanEnabledKey) private var smartScanEnabled = true

    // Per-row icon tints (from the Claude design): purple categories, green tax,
    // ocean-blue banks. App-group rows use the neutral ink/paper treatment.
    private let categoriesTint = Color(hex: 0x7B5BD6)
    private let categoriesSoft = Color(hex: 0xEBE5F8)
    private let banksTint = Color(hex: 0x2F6FB0)
    private let banksSoft = Color(hex: 0xE2ECF6)

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("Profile").font(.display(30)).tracking(-0.6).foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)

                identityHeader

                // Profile switcher grid.
                groupLabel("Profiles · \(profiles.profiles.count)")
                profileSwitcher

                captureAndTaxGroup
                appGroup
                accountGroup

                Button(action: onSignOut) {
                    HStack(spacing: 8) {
                        Icon(name: "logout", size: 19, color: Palette.alert)
                        Text("Sign out").font(.ui(15, .bold)).foregroundStyle(Palette.alert)
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Palette.paper, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .strokeBorder(Palette.line, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.signOutButton)
                .padding(.top, 8)

                Text("Snapceipt · v1.0 · Snap it. Sort it. Sorted.")
                    .font(.ui(12)).foregroundStyle(Palette.ink3)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 16)
            }
            .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 110)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.profileHubScreen)
    }

    /// Capture & tax group: AI toggle + categories/tax/banks rows in one shared card.
    private var captureAndTaxGroup: some View {
        VStack(spacing: 14) {
            groupLabel("Capture & tax")
            Card(padding: 16) {
                VStack(spacing: 0) {
                    aiAutoCategoriseRow
                    rowDivider
                    smartScanRow
                    rowDivider
                    settingRow(icon: "tag", title: "Categories & rules", detail: nil,
                               tint: categoriesTint, soft: categoriesSoft,
                               id: AccessibilityID.profileRowCategories, action: onOpenCategories)
                    rowDivider
                    settingRow(icon: "shield", title: "Tax & GST settings", detail: nil,
                               tint: Palette.income, soft: Palette.incomeSoft,
                               id: AccessibilityID.profileRowTax, action: onOpenTax)
                    rowDivider
                    connectedBanksRow
                }
            }
        }
    }

    /// App group: notifications, budgets, email-in, export, privacy, legal, help.
    /// Built from a descriptor array so the divider-separated list isn't bound by the
    /// 10-view `@ViewBuilder` limit.
    private var appGroup: some View {
        let rows: [SettingRowSpec] = [
            .init(icon: "bell", title: "Notifications & alerts",
                  id: AccessibilityID.profileRowNotifications, action: onOpenNotifications),
            .init(icon: "wallet", title: "Budgets",
                  id: AccessibilityID.profileRowBudgets, action: onOpenBudgets),
            .init(icon: "receipt", title: "Email-in receipts",
                  id: AccessibilityID.profileRowEmailIn, action: onOpenEmailIn),
            .init(icon: "download", title: "Export & backup",
                  id: "profile.row.export", action: onOpenExport),
            .init(icon: "lock", title: "Privacy & security",
                  id: AccessibilityID.profileRowPrivacy, action: onOpenPrivacy),
            .init(icon: "doc", title: "Terms & Privacy",
                  id: AccessibilityID.profileRowLegal, action: openTerms),
            .init(icon: "info", title: "Help & support",
                  id: AccessibilityID.profileRowHelp, action: openSupport),
        ]
        return VStack(spacing: 14) {
            groupLabel("App")
            Card(padding: 16) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, spec in
                        if idx > 0 { rowDivider }
                        settingRow(icon: spec.icon, title: spec.title, detail: nil,
                                   tint: Palette.ink2, soft: Palette.paper2,
                                   id: spec.id, action: spec.action)
                    }
                }
            }
        }
    }

    /// Account group: the single Account row in its own shared card.
    private var accountGroup: some View {
        VStack(spacing: 14) {
            groupLabel("Account")
            Card(padding: 16) {
                settingRow(icon: "user", title: "Account", detail: nil,
                           tint: Palette.ink2, soft: Palette.paper2,
                           id: AccessibilityID.profileRowAccount, action: onOpenAccount)
            }
        }
    }

    /// Identity header: gradient initials avatar + name/email (data-bound; no hardcoded name).
    private var identityHeader: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [accent.base, accent.deep],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .frame(width: 60, height: 60)
                .overlay(
                    Text(avatarInitials)
                        .font(.display(24, .bold)).foregroundStyle(.white)
                )
                .shadow(color: accent.base.opacity(0.4), radius: 12, x: 0, y: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(userName).font(.ui(19, .bold)).foregroundStyle(Palette.ink)
                if let e = userEmail { Text(e).font(.ui(13.5)).foregroundStyle(Palette.ink3) }
            }
            Spacer()
        }
    }

    /// Initials for the identity avatar — derived from the signed-in user's name.
    private var avatarInitials: String {
        let parts = userName.split(separator: " ").prefix(2)
        let s = parts.compactMap { $0.first }.map(String.init).joined().uppercased()
        return s.isEmpty ? "?" : s
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
        Text(s.uppercased()).font(.ui(13, .bold)).tracking(0.3).foregroundStyle(Palette.ink3)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
    }

    /// Hairline between rows inside a shared settings card.
    private var rowDivider: some View {
        Divider().overlay(Palette.line2)
    }

    /// A tappable setting row inside a shared card: tinted icon tile, label, optional
    /// right-aligned `detail`, and a chevron. Rows sit flush so the enclosing card
    /// supplies the horizontal padding and dividers separate them.
    private func settingRow(icon: String, title: String, detail: String?,
                            tint: Color, soft: Color, id: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                IconCircle(name: icon, tint: tint, soft: soft, size: 36, iconSize: 19)
                Text(title).font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
                Spacer()
                if let detail { Text(detail).font(.ui(13.5)).foregroundStyle(Palette.ink3) }
                Icon(name: "chevR", size: 17, color: Palette.ink3)
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    /// Inert AI auto-categorise toggle (defaults ON; purely visual, drives no behaviour).
    private var aiAutoCategoriseRow: some View {
        HStack(spacing: 12) {
            IconCircle(name: "sparkles", tint: accent.base, soft: accent.soft, size: 36, iconSize: 19)
            Text("AI auto-categorise").font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
            Spacer()
            Toggle("", isOn: $aiAutoCategorise).labelsHidden().tint(Palette.income)
        }
        .padding(.vertical, 13)
        .accessibilityIdentifier(AccessibilityID.profileAiAutoCategorise)
    }

    /// Real, persisted Smart Scan toggle (distinct from the inert aiAutoCategoriseRow).
    private var smartScanRow: some View {
        HStack(spacing: 12) {
            IconCircle(name: "sparkles", tint: accent.base, soft: accent.soft, size: 36, iconSize: 19)
            VStack(alignment: .leading, spacing: 1) {
                Text("Smart Scan AI").font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
                Text("Use AI to read receipts").font(.ui(12)).foregroundStyle(Palette.ink3)
            }
            Spacer()
            Toggle("", isOn: $smartScanEnabled).labelsHidden().tint(Palette.income)
        }
        .padding(.vertical, 13)
        .accessibilityIdentifier(AccessibilityID.profileSmartScanToggle)
    }

    /// Connected banks — Coming-soon placeholder. Disabled, no action, no network
    /// (mirrors the MileageScreen GPS-card treatment: dimmed with a "Coming soon" label).
    private var connectedBanksRow: some View {
        HStack(spacing: 12) {
            IconCircle(name: "bank", tint: banksTint, soft: banksSoft, size: 36, iconSize: 19)
            VStack(alignment: .leading, spacing: 1) {
                Text("Connected banks").font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
                Text("Coming soon").font(.ui(12.5)).foregroundStyle(Palette.ink3)
            }
            Spacer()
        }
        .padding(.vertical, 13)
        .opacity(0.7)
        .accessibilityIdentifier(AccessibilityID.profileRowConnectedBanks)
    }

    /// Legal — opens the external Terms of Service page via the SwiftUI openURL action.
    /// (The Privacy Policy is reachable from there and from the sign-in disclaimer.)
    private func openTerms() {
        if let url = URL(string: "https://snapceipt.cc/terms") { openURL(url) }
    }

    /// Help & support — opens the external help site via the SwiftUI openURL action.
    private func openSupport() {
        if let url = URL(string: "https://snapceipt.cc/support") { openURL(url) }
    }
}

/// Lightweight descriptor for a tappable App-group setting row (drives the
/// descriptor-array build that keeps the divider list under the ViewBuilder limit).
private struct SettingRowSpec {
    let icon: String
    let title: String
    let id: String
    let action: () -> Void
}
