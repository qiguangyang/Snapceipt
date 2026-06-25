import SwiftUI

/// Dedicated "Reset your password" page, pushed from the email login page. Collects an email and
/// requests a 6-digit code (`.reset`); the code screen then routes to set-password (not skippable).
struct ForgotPasswordView: View {
    @Environment(AuthViewModel.self) private var vm
    @State private var email = ""
    @FocusState private var focused: Bool

    private var isBusy: Bool { vm.state == .working }

    var body: some View {
        VStack(spacing: 0) {
            AuthBackButton(disabled: isBusy)
            ScrollView {
                VStack(spacing: 18) {
                    AuthPageHeader(title: "Reset your password",
                                   subtitle: "Enter your email and we'll send a 6-digit code to reset your password.")
                        .padding(.top, 8)

                    VStack(spacing: 12) {
                        TextField("you@example.com", text: $email)
                            .keyboardType(.emailAddress)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .focused($focused)
                            .onSubmit { send() }
                            .authField()
                            .accessibilityIdentifier(AccessibilityID.forgotEmail)

                        AuthErrorText(message: vm.lastError)

                        AuthPrimaryButton(title: "Send reset code", busy: isBusy,
                                          enabled: !email.isEmpty) { send() }
                            .accessibilityIdentifier(AccessibilityID.forgotSubmit)
                    }
                    .padding(.horizontal, 24)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .keyboardDismissButton()
        .onAppear { vm.clearError(); focused = true }
    }

    private func send() {
        let e = email
        Task { await vm.startCode(email: e, purpose: .reset) }
    }
}

#if DEBUG
#Preview("Forgot password") {
    NavigationStack {
        ForgotPasswordView()
            .environment(AuthViewModel(api: PreviewAPIClient(),
                                       auth: AuthStore(keychain: Keychain(service: "sc.preview"))))
            .environment(\.accent, .personal)
    }
}
#endif
