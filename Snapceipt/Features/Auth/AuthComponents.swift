import SwiftUI

// Shared building blocks for the auth screens (landing + email login + create-account +
// forgot-password). Kept in one place so the pushed sub-pages stay DRY and on-brand.

/// Routes for the signed-out NavigationStack rooted in `SignInView`.
enum AuthRoute: Hashable { case emailLogin, createAccount, forgotPassword }

/// Paper-filled rounded text-field chrome shared by the auth screens.
struct AuthFieldChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.ui(16))
            .padding(.horizontal, 14)
            .frame(height: 54)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Palette.line, lineWidth: 1))
    }
}

extension View {
    /// Apply the shared auth text-field chrome.
    func authField() -> some View { modifier(AuthFieldChrome()) }
}

/// Full-width accent CTA used across the auth screens; shows a spinner while `busy`,
/// dims when disabled.
struct AuthPrimaryButton: View {
    let title: String
    var busy: Bool = false
    var enabled: Bool = true
    let action: () -> Void
    @Environment(\.accent) private var accent

    var body: some View {
        Button(action: action) {
            Group {
                if busy { ProgressView().tint(.white) } else { Text(title) }
            }
            .font(.ui(16, .semibold)).foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(accent.base, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(enabled && !busy ? 1 : 0.5)
        }
        .disabled(!enabled || busy)
    }
}

/// Inline alert message (renders nothing when nil).
struct AuthErrorText: View {
    let message: String?
    var body: some View {
        if let message {
            Text(message)
                .font(.ui(13)).foregroundStyle(Palette.alert)
                .multilineTextAlignment(.center)
        }
    }
}

/// Top-left back chevron for the pushed auth sub-pages (the nav bar is hidden to keep the
/// full-bleed cream look). Pops the NavigationStack. `disabled` while a request is in flight so
/// the user can't pop away mid-request and have a late failure surface on the landing.
struct AuthBackButton: View {
    var disabled: Bool = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.ink2)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Back")
            .disabled(disabled)
            .opacity(disabled ? 0.4 : 1)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }
}

/// The Snapceipt brand lockup (icon + wordmark + tagline) shown on the auth landing.
struct AuthBrandHeader: View {
    @Environment(\.accent) private var accent
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [accent.base, accent.deep],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 78, height: 78)
                    .shadow(color: accent.base.opacity(0.45), radius: 18, x: 0, y: 10)
                Image(systemName: "doc.viewfinder")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("Snapceipt").font(.display(30, .bold)).foregroundStyle(Palette.ink)
            Text("Snap receipts. Sort your tax. Done.")
                .font(.ui(15)).foregroundStyle(Palette.ink2).multilineTextAlignment(.center)
        }
    }
}

/// Compact title + subtitle header for the pushed auth sub-pages.
struct AuthPageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.display(26, .bold)).foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.ui(15)).foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 12)
    }
}
