import SwiftUI

/// "Check your email" screen shown after a magic link is requested. Offers resend,
/// a "use a different email" escape back to signed-out, and an expired/invalid
/// error branch (when `vm.state == .error`) with a "send a new link" retry.
struct MagicLinkWaitView: View {
    @Environment(AuthViewModel.self) private var vm
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(accent.soft)
                    .frame(width: 96, height: 96)
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "envelope.fill")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(isError ? Palette.alert : accent.base)
            }
            .padding(.bottom, 22)

            Text(isError ? "Link expired" : "Check your email")
                .font(.display(24, .bold))
                .foregroundStyle(Palette.ink)
                .padding(.bottom, 8)

            Text(subtitle)
                .font(.ui(15))
                .foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, 36)

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                Button { Task { await vm.resendMagicLink() } } label: {
                    Text(isError ? "Send a new link" : "Resend email")
                        .font(.ui(16, .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(accent.base, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                Button { Task { await vm.signOut() } } label: {
                    Text("Use a different email")
                        .font(.ui(15, .semibold))
                        .foregroundStyle(Palette.ink2)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream.ignoresSafeArea())
    }

    private var isError: Bool {
        if case .error = vm.state { return true }
        return false
    }

    private var subtitle: String {
        if case .error(let message) = vm.state { return message }
        let email = vm.pendingEmail ?? "your inbox"
        return "We sent a sign-in link to \(email). Tap it on this device to continue."
    }
}

#if DEBUG
#Preview("Waiting") {
    let vm = AuthViewModel(api: PreviewAPIClient(),
                           auth: AuthStore(keychain: Keychain(service: "sc.preview")))
    return MagicLinkWaitView()
        .environment(vm)
        .environment(\.accent, .personal)
        .task { await vm.requestMagicLink(email: "maya@example.com") }
}
#endif
