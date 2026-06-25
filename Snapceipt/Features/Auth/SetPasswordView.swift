import SwiftUI

/// Set a password after a sign-up or reset code (the user is already signed in via the code).
/// Sign-up may skip ("code login still works"); a reset must set a new one. Minimum 8 characters;
/// a server-side failure surfaces via `vm.lastError`.
struct SetPasswordView: View {
    @Environment(AuthViewModel.self) private var vm
    @Environment(\.accent) private var accent
    @State private var password = ""
    @State private var confirm = ""
    @State private var busy = false
    @FocusState private var focus: Field?
    private enum Field { case password, confirm }

    private var isReset: Bool { vm.codePurpose == .reset }
    private var canSubmit: Bool { password.count >= 8 && password == confirm && !busy }

    var body: some View {
        VStack(spacing: 18) {
            Text(isReset ? "Choose a new password" : "Set a password")
                .font(.display(22, .bold)).foregroundStyle(Palette.ink)
                .padding(.top, 44)

            Text("You'll use this with your email to sign in. At least 8 characters.")
                .font(.ui(15)).foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)

            SecureField("Password", text: $password)
                .textContentType(.newPassword)
                .submitLabel(.next)
                .focused($focus, equals: .password)
                .onSubmit { focus = .confirm }
                .modifier(PwField())
                .accessibilityIdentifier(AccessibilityID.setPasswordField)

            SecureField("Confirm password", text: $confirm)
                .textContentType(.newPassword)
                .submitLabel(.go)
                .focused($focus, equals: .confirm)
                .onSubmit { if canSubmit { submit() } }
                .modifier(PwField())

            if let err = vm.lastError {
                Text(err).font(.ui(13)).foregroundStyle(Palette.alert)
                    .multilineTextAlignment(.center)
            } else if !confirm.isEmpty && password != confirm {
                Text("Passwords don't match.").font(.ui(13)).foregroundStyle(Palette.alert)
            }

            Button(action: submit) {
                Group {
                    if busy { ProgressView().tint(.white) }
                    else { Text(isReset ? "Update password" : "Set password") }
                }
                .font(.ui(16, .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(accent.base, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .opacity(canSubmit ? 1 : 0.5)
            }
            .disabled(!canSubmit)
            .accessibilityIdentifier(AccessibilityID.setPasswordSubmit)

            if vm.canSkipPasswordSetup {
                Button("Skip for now") { vm.skipPasswordSetup() }
                    .font(.ui(14, .semibold)).foregroundStyle(Palette.ink2)
                    .accessibilityIdentifier(AccessibilityID.setPasswordSkip)
                    .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
        .background(Palette.cream.ignoresSafeArea())
        .keyboardDismissButton()
    }

    private func submit() {
        let pw = password
        busy = true
        Task {
            _ = await vm.setPassword(pw)
            busy = false
        }
    }
}

/// Paper-filled rounded field chrome for the password fields.
private struct PwField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.ui(16))
            .padding(.horizontal, 14)
            .frame(height: 54)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Palette.line, lineWidth: 1))
    }
}

#if DEBUG
#Preview("Set password") {
    SetPasswordView()
        .environment(AuthViewModel(api: PreviewAPIClient(),
                                   auth: AuthStore(keychain: Keychain(service: "sc.preview"))))
        .environment(\.accent, .personal)
}
#endif
