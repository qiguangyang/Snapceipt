import SwiftUI

/// "Check your email" screen shown after a magic link is requested. Offers resend,
/// a "use a different email" escape back to signed-out, and an expired/invalid
/// error branch (when `vm.state == .error`) with a "send a new link" retry.
struct MagicLinkWaitView: View {
    @Environment(AuthViewModel.self) private var vm
    @Environment(\.accent) private var accent

    /// How long the "Link sent" confirmation stays up after a successful (re)send.
    private static let confirmationDuration: Duration = .milliseconds(1600)

    /// The `vm.linkSentCount` value this view is currently confirming. Each successful
    /// send bumps the VM's count; the `.task(id:)` below re-runs, shows the checkmark
    /// for `confirmationDuration`, then clears it. Driving the confirmation off the VM
    /// (not local `@State` seeded inside `resend()`) means it survives the
    /// `.requestingLink → .awaitingLink` view recreation RootView performs, and a fresh
    /// send's `.task(id:)` cancellation supersedes the prior timer (no stale truncation).
    @State private var confirmedCount = 0
    @State private var showingCodeEntry = false

    /// True while the confirmation window for the latest successful send is open.
    private var justSent: Bool { confirmedCount > 0 && confirmedCount == vm.linkSentCount }

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
                Button { resend() } label: {
                    Group {
                        if isSending {
                            ProgressView().tint(.white)
                        } else if justSent && !isError {
                            Label("Link sent", systemImage: "checkmark")
                        } else {
                            Text(isError ? "Send a new link" : "Resend email")
                        }
                    }
                    .font(.ui(16, .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(accent.base, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .disabled(isSending)

                Button { Task { await vm.signOut() } } label: {
                    Text("Use a different email")
                        .font(.ui(15, .semibold))
                        .foregroundStyle(Palette.ink2)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                Button { showingCodeEntry = true } label: {
                    Text("Enter a code instead")
                        .font(.ui(15, .semibold))
                        .foregroundStyle(accent.base)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream.ignoresSafeArea())
        // Confirmation timer keyed on the VM's successful-send count: each new send
        // supersedes the prior one (old `.task` is cancelled), and the count living on
        // the VM keeps the confirmation alive across RootView's wait-screen recreation.
        .task(id: vm.linkSentCount) {
            guard vm.linkSentCount > 0, !isError else { return }
            withAnimation { confirmedCount = vm.linkSentCount }
            try? await Task.sleep(for: Self.confirmationDuration)
            withAnimation { confirmedCount = 0 }
        }
        .sheet(isPresented: $showingCodeEntry) {
            OTPEntryView()
                .environment(vm)
                .environment(\.accent, accent)
        }
    }

    /// True while a (re)send request is in flight — drives the inline spinner.
    private var isSending: Bool { vm.state == .requestingLink }

    /// Resend the link. The in-flight window is covered by the spinner (driven by
    /// `vm.state`); on success the VM bumps `linkSentCount`, which re-fires the
    /// `.task(id:)` above to flash the "Link sent" confirmation.
    private func resend() {
        Task { await vm.resendMagicLink() }
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
