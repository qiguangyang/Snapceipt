import SwiftUI

/// 6-digit sign-in code entry — the cross-device fallback presented from the
/// magic-link wait screen. On success the VM transitions to .signedIn and the
/// RootView swaps this whole flow out, dismissing the sheet implicitly.
struct OTPEntryView: View {
    @Environment(AuthViewModel.self) private var vm
    @Environment(\.accent) private var accent
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""

    private var isVerifying: Bool { vm.state == .verifying }

    var body: some View {
        VStack(spacing: 20) {
            Text("Enter your sign-in code")
                .font(.display(22, .bold))
                .foregroundStyle(Palette.ink)
                .padding(.top, 28)

            Text("We emailed a 6-digit code to \(vm.pendingEmail ?? "your inbox").")
                .font(.ui(15))
                .foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            TextField("123456", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .multilineTextAlignment(.center)
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(accent.soft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 24)
                .onChange(of: code) { _, new in
                    code = String(new.filter(\.isNumber).prefix(6))
                }

            Button { Task { await vm.verifyOTP(code: code) } } label: {
                Group {
                    if isVerifying { ProgressView().tint(.white) } else { Text("Sign in") }
                }
                .font(.ui(16, .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(accent.base, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(code.count != 6 || isVerifying)
            .padding(.horizontal, 24)

            if case .error(let message) = vm.state {
                Text(message)
                    .font(.ui(13))
                    .foregroundStyle(Palette.alert)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream.ignoresSafeArea())
        .keyboardDismissButton()
    }
}

#if DEBUG
#Preview("OTP entry") {
    let vm = AuthViewModel(api: PreviewAPIClient(),
                           auth: AuthStore(keychain: Keychain(service: "sc.preview")))
    return OTPEntryView()
        .environment(vm)
        .environment(\.accent, .personal)
        .task { await vm.requestOTP(email: "maya@example.com") }
}
#endif
