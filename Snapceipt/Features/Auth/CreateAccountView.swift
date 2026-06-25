import SwiftUI

/// Dedicated "Create your account" page, pushed from the landing. Collects an email and requests
/// a 6-digit confirmation code (`.signUp`), which advances to the code screen → set-password.
struct CreateAccountView: View {
    @Environment(AuthViewModel.self) private var vm
    @State private var email = ""
    @FocusState private var focused: Bool

    private var isBusy: Bool { vm.state == .working }

    var body: some View {
        VStack(spacing: 0) {
            AuthBackButton(disabled: isBusy)
            ScrollView {
                VStack(spacing: 18) {
                    AuthPageHeader(title: "Create your account",
                                   subtitle: "We'll email you a 6-digit code to confirm your address. You'll set a password next.")
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
                            .accessibilityIdentifier(AccessibilityID.createEmail)

                        AuthErrorText(message: vm.lastError)

                        AuthPrimaryButton(title: "Send verification code", busy: isBusy,
                                          enabled: !email.isEmpty) { send() }
                            .accessibilityIdentifier(AccessibilityID.createSubmit)
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
        Task { await vm.startCode(email: e, purpose: .signUp) }
    }
}

#if DEBUG
#Preview("Create account") {
    NavigationStack {
        CreateAccountView()
            .environment(AuthViewModel(api: PreviewAPIClient(),
                                       auth: AuthStore(keychain: Keychain(service: "sc.preview"))))
            .environment(\.accent, .personal)
    }
}
#endif
