import SwiftUI

/// Dedicated email + password sign-in page, pushed from the landing's "Sign in with Email".
/// A password login on a NEW device is challenged with a 6-digit code on the next screen (2FA).
/// "Forgot password?" pushes the reset page; "Email me a code instead" is the passwordless path.
///
/// The two actions (password sign-in vs. send-a-code) use LOCAL busy flags rather than the shared
/// `vm.state == .working`, so the spinner always appears on the control the user tapped, and a
/// second action can't be fired (or the back button used) while one is in flight.
struct EmailLoginView: View {
    @Environment(AuthViewModel.self) private var vm
    @Environment(\.accent) private var accent
    @State private var email = ""
    @State private var password = ""
    @State private var passwordBusy = false
    @State private var codeBusy = false
    @FocusState private var focus: Field?
    private enum Field { case email, password }

    private var anyBusy: Bool { passwordBusy || codeBusy }

    var body: some View {
        VStack(spacing: 0) {
            AuthBackButton(disabled: anyBusy)
            ScrollView {
                VStack(spacing: 18) {
                    AuthPageHeader(title: "Sign in",
                                   subtitle: "Welcome back. Enter your email and password.")
                        .padding(.top, 8)

                    VStack(spacing: 12) {
                        TextField("you@example.com", text: $email)
                            .keyboardType(.emailAddress)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .focused($focus, equals: .email)
                            .onSubmit { focus = .password }
                            .authField()
                            .accessibilityIdentifier(AccessibilityID.signInEmail)

                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .submitLabel(.go)
                            .focused($focus, equals: .password)
                            .onSubmit { signIn() }
                            .authField()
                            .accessibilityIdentifier(AccessibilityID.signInPassword)

                        AuthErrorText(message: vm.lastError)

                        AuthPrimaryButton(title: "Sign in", busy: passwordBusy,
                                          enabled: !email.isEmpty && !password.isEmpty && !codeBusy) {
                            signIn()
                        }
                        .accessibilityIdentifier(AccessibilityID.signInSubmit)

                        HStack {
                            NavigationLink(value: AuthRoute.forgotPassword) {
                                Text("Forgot password?")
                                    .font(.ui(13, .semibold)).foregroundStyle(accent.base)
                            }
                            .accessibilityIdentifier(AccessibilityID.signInForgot)
                            .disabled(anyBusy)
                            Spacer()
                        }
                        .padding(.top, 2)

                        Button { sendCode() } label: {
                            Group {
                                if codeBusy { ProgressView().controlSize(.small) }
                                else { Text("Email me a sign-in code instead") }
                            }
                            .font(.ui(14, .semibold)).foregroundStyle(Palette.ink2)
                        }
                        .disabled(anyBusy || email.isEmpty)
                        .accessibilityIdentifier(AccessibilityID.signInUseCode)
                        .padding(.top, 8)
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
        .onAppear { vm.clearError(); focus = .email }
    }

    private func signIn() {
        guard !anyBusy else { return }
        let e = email, p = password
        passwordBusy = true
        Task { await vm.signInWithPassword(email: e, password: p); passwordBusy = false }
    }

    private func sendCode() {
        guard !anyBusy else { return }
        let e = email
        codeBusy = true
        Task { await vm.startCode(email: e, purpose: .codeLogin); codeBusy = false }
    }
}

#if DEBUG
#Preview("Email login") {
    NavigationStack {
        EmailLoginView()
            .environment(AuthViewModel(api: PreviewAPIClient(),
                                       auth: AuthStore(keychain: Keychain(service: "sc.preview"))))
            .environment(\.accent, .personal)
    }
}
#endif
