import SwiftUI

/// 6-digit code entry — used for sign-up, password reset, passwordless login, and new-device
/// MFA. The code was already requested (by the sign-in screen, or emailed automatically by a
/// new-device password login), so this screen does NOT request on appear; it verifies on submit
/// and offers a resend. `vm.codePurpose` drives the heading + CTA copy.
struct CodeEntryView: View {
    @Environment(AuthViewModel.self) private var vm
    @Environment(\.accent) private var accent
    @State private var code = ""
    @State private var justSent = false

    private var isVerifying: Bool { vm.state == .verifying }

    private var title: String {
        switch vm.codePurpose {
        case .signUp:    return "Confirm your email"
        case .reset:     return "Reset your password"
        case .mfa:       return "Verify it's you"
        case .codeLogin: return "Enter your sign-in code"
        }
    }
    private var subtitle: String {
        let inbox = vm.pendingEmail ?? "your inbox"
        if vm.codePurpose == .mfa {
            return "New device — we emailed a 6-digit code to \(inbox)."
        }
        return "We emailed a 6-digit code to \(inbox)."
    }
    private var cta: String { (vm.codePurpose == .signUp || vm.codePurpose == .reset) ? "Continue" : "Sign in" }

    var body: some View {
        VStack(spacing: 20) {
            Text(title)
                .font(.display(22, .bold)).foregroundStyle(Palette.ink)
                .padding(.top, 40)

            Text(subtitle)
                .font(.ui(15)).foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center).padding(.horizontal, 32)

            TextField("123456", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .multilineTextAlignment(.center)
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(accent.soft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 24)
                .onChange(of: code) { _, new in code = String(new.filter(\.isNumber).prefix(6)) }
                .accessibilityIdentifier(AccessibilityID.codeField)

            Button { Task { await vm.verifyCode(code) } } label: {
                Group {
                    if isVerifying { ProgressView().tint(.white) } else { Text(cta) }
                }
                .font(.ui(16, .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(accent.base, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(code.count != 6 || isVerifying)
            .padding(.horizontal, 24)
            .accessibilityIdentifier(AccessibilityID.codeSubmit)

            if let err = vm.lastError {
                Text(err)
                    .font(.ui(13)).foregroundStyle(Palette.alert)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
            }

            HStack(spacing: 18) {
                Button(justSent ? "Code sent ✓" : "Resend code") { Task { await vm.resendCode() } }
                    .font(.ui(14, .semibold))
                    .foregroundStyle(justSent ? Palette.ink3 : accent.base)
                    .disabled(justSent || isVerifying)
                Button("Use a different email") { vm.cancelFlow() }
                    .font(.ui(14, .semibold)).foregroundStyle(Palette.ink2)
            }
            .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream.ignoresSafeArea())
        .keyboardDismissButton()
        // Flash "Code sent ✓" for ~1.6s after every successful (re)send; `codeSentCount` changes
        // on each send, re-running this timer.
        .task(id: vm.codeSentCount) {
            guard vm.codeSentCount > 0 else { return }
            justSent = true
            try? await Task.sleep(for: .seconds(1.6))
            justSent = false
        }
    }
}

#if DEBUG
#Preview("Code entry") {
    let vm = AuthViewModel(api: PreviewAPIClient(),
                           auth: AuthStore(keychain: Keychain(service: "sc.preview")))
    return CodeEntryView()
        .environment(vm)
        .environment(\.accent, .personal)
        .task { await vm.startCode(email: "maya@example.com", purpose: .signUp) }
}
#endif
