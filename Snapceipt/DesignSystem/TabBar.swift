import SwiftUI

/// A single non-center tab button (home/activity/reports/profile).
private struct TabItem: View {
    let iconName: String
    let label: String
    let isActive: Bool
    let accent: AccentPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Icon(name: iconName, size: 23, color: isActive ? accent.base : Palette.ink3)
                Text(label)
                    .font(.ui(10.5, .semibold))
                    .foregroundStyle(isActive ? accent.base : Palette.ink3)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Frosted, floating raised-center tab bar (Home / Activity / Snap-FAB / Reports /
/// Profile). The center Snap FAB opens Capture and never changes the active tab
/// (`Router.go(.tab(.snap))` routes to the capture overlay). 64pt bar, frosted
/// material, 26pt corner radius, accent FAB raised −26.
struct TabBar: View {
    @Bindable var router: Router
    let accent: AccentPalette

    var body: some View {
        HStack(spacing: 0) {
            TabItem(iconName: "home", label: "Home",
                    isActive: router.tab == .home, accent: accent) {
                router.go(.tab(.home))
            }
            .accessibilityIdentifier(AccessibilityID.tabHome)
            TabItem(iconName: "receipt", label: "Activity",
                    isActive: router.tab == .activity, accent: accent) {
                router.go(.tab(.activity))
            }
            .accessibilityIdentifier(AccessibilityID.tabActivity)

            // Center Snap FAB — raised, accent gradient, 3pt cream ring, FAB shadow.
            Button {
                router.go(.tab(.snap)) // routed to the capture overlay (never sets .snap)
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [accent.base, accent.deep],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 58, height: 58)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(Palette.cream, lineWidth: 3)
                        )
                        .shadow(color: accent.base.opacity(0.55), radius: 12, x: 0, y: 8)
                        .shadow(color: Palette.ink.opacity(0.18), radius: 4, x: 0, y: 3)
                    Icon(name: "camera", size: 28, color: .white)
                }
                .offset(y: -26)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier(AccessibilityID.tabSnap)

            TabItem(iconName: "chart", label: "Reports",
                    isActive: router.tab == .reports, accent: accent) {
                router.go(.tab(.reports))
            }
            .accessibilityIdentifier(AccessibilityID.tabReports)
            TabItem(iconName: "user", label: "Profile",
                    isActive: router.tab == .profile, accent: accent) {
                router.go(.tab(.profile))
            }
            .accessibilityIdentifier(AccessibilityID.tabProfile)
        }
        .padding(.horizontal, 10)
        .frame(height: 64)
        .background(.regularMaterial)
        .background(Palette.paper.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Palette.line, lineWidth: 1)
        )
        .cardShadow()
        .padding(.horizontal, 16)
    }
}

/// Placeholder content for non-foundation tabs (Activity / Reports / Profile land
/// in later phases). Renders a calm centered "coming soon" message.
struct StubTabView: View {
    let title: String
    let accent: AccentPalette

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(accent.soft).frame(width: 96, height: 96)
                Icon(name: "receipt", size: 34, color: accent.base)
            }
            Text(title)
                .font(.display(20))
                .foregroundStyle(Palette.ink)
            Text("Coming soon")
                .font(.ui(13.5))
                .foregroundStyle(Palette.ink3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream)
    }
}

#if DEBUG
#Preview {
    ZStack(alignment: .bottom) {
        Palette.cream.ignoresSafeArea()
        TabBar(router: Router(), accent: .personal)
    }
}
#endif
