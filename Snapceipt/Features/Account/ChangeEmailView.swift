import SwiftUI

/// Change-email flow (F7, spec §8.1). A two-step overlay driven by its own
/// `AccountViewModel` instance (the VM is stateless except the in-flight code, so a
/// fresh instance against the same `auth`/`api` is correct): enter the new address →
/// "Send code" issues a 6-digit code to it (`requestEmailChange`); once
/// `vm.codeSent`, enter the code → "Verify" commits the swap (`verifyEmailChange`,
/// which updates the persisted session email) and closes the overlay. Inline errors
/// surface invalid-email validation and wrong/expired codes.
struct ChangeEmailView: View {
    let api: any APIClient
    let auth: AuthStore
    let onClose: () -> Void

    @Environment(\.accent) private var accent
    @State private var vm: AccountViewModel?

    var body: some View {
        ZStack {
            Palette.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                SheetHeader(title: "Change email", onClose: onClose)
                if let vm {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            newEmailCard(vm)
                            if vm.codeSent { codeCard(vm) }
                            if let err = vm.errorMessage {
                                Text(err).font(.ui(12.5, .regular)).foregroundStyle(Palette.alert)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 60)
                    }
                } else { Color.clear }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.changeEmailScreen)
        .transition(.opacity)
        .task {
            if vm == nil {
                vm = AccountViewModel(api: api, auth: auth, currentDeviceId: auth.deviceId,
                                      onSignedOut: {})
            }
        }
    }

    @ViewBuilder private func newEmailCard(_ vm: AccountViewModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New email").font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
                    TextField("you@example.com", text: Binding(
                        get: { vm.newEmail }, set: { vm.newEmail = $0 }))
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(vm.codeSent)
                        .padding(12).background(Palette.paper2, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier(AccessibilityID.changeEmailField)
                }
                Button {
                    Task { await vm.requestCode() }
                } label: {
                    Text(vm.codeSent ? "Resend code" : "Send code")
                        .font(.ui(14.5, .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(accent.base, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(vm.busy)
                .accessibilityIdentifier(AccessibilityID.changeEmailSend)
            }
        }
    }

    @ViewBuilder private func codeCard(_ vm: AccountViewModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Enter the 6-digit code").font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
                    TextField("000000", text: Binding(
                        get: { vm.code }, set: { vm.code = $0 }))
                        .keyboardType(.numberPad)
                        .padding(12).background(Palette.paper2, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier(AccessibilityID.changeEmailCodeField)
                }
                Button {
                    Task { await vm.verifyCode(); if vm.errorMessage == nil && !vm.codeSent { onClose() } }
                } label: {
                    Text("Verify")
                        .font(.ui(14.5, .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(accent.base, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(vm.busy)
                .accessibilityIdentifier(AccessibilityID.changeEmailVerify)
            }
        }
    }
}
