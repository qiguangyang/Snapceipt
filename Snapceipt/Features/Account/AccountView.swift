import SwiftUI

/// Account & security screen (F7, spec §8). Mirrors `NotificationsSettingsView`/
/// `TaxSettingsView` chrome (cream background, `SheetHeader`, a `ScrollView` of
/// grouped `Card`s) and drives an `AccountViewModel`:
/// - **Email** — shows the current address + a "Change email" button that routes
///   to the `.changeEmail` overlay.
/// - **Devices** — the signed-in device list from `me()`, each with a "Sign out"
///   button gated behind a `confirmationDialog`; the current device is labelled.
/// - **Danger zone** — "Delete account" reveals a typed-`DELETE` confirmation gate
///   before the destructive call. Revoking the current device or deleting the
///   account clears the session and signs out via `authVM.signOut()`.
struct AccountView: View {
    let api: any APIClient
    let auth: AuthStore
    let authVM: AuthViewModel
    let onChangeEmail: () -> Void
    let onClose: () -> Void

    @Environment(\.accent) private var accent
    @State private var vm: AccountViewModel?
    @State private var revokeTarget: DeviceDTO?
    @State private var showDelete = false
    @State private var confirmText = ""

    var body: some View {
        ZStack {
            Palette.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                SheetHeader(title: "Account", onClose: onClose)
                if let vm {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            emailSection(vm)
                            devicesSection(vm)
                            dangerZone(vm)
                            if let err = vm.errorMessage {
                                Text(err).font(.ui(12.5, .regular)).foregroundStyle(Palette.alert)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 60)
                    }
                    .task { await vm.loadDevices() }
                } else { Color.clear }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.accountScreen)
        .transition(.opacity)
        .task {
            if vm == nil {
                vm = AccountViewModel(api: api, auth: auth, currentDeviceId: auth.deviceId,
                                      onSignedOut: { Task { await authVM.signOut() } })
            }
        }
    }

    // MARK: - Email

    @ViewBuilder private func emailSection(_ vm: AccountViewModel) -> some View {
        groupLabel("Email")
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Signed in as").font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                    Spacer()
                    Text(vm.email ?? "—").font(.ui(14.5, .regular)).foregroundStyle(Palette.ink2)
                        .lineLimit(1).truncationMode(.middle)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityID.accountEmailRow)
                Button(action: onChangeEmail) {
                    HStack {
                        Text("Change email").font(.ui(14.5, .semibold)).foregroundStyle(accent.base)
                        Spacer()
                        Icon(name: "chevR", size: 16, color: Palette.ink3)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.accountChangeEmail)
            }
        }
    }

    // MARK: - Devices

    @ViewBuilder private func devicesSection(_ vm: AccountViewModel) -> some View {
        groupLabel("Devices")
        Card {
            VStack(alignment: .leading, spacing: 14) {
                if vm.devices.isEmpty {
                    Text("No other devices.").font(.ui(14.5, .regular)).foregroundStyle(Palette.ink2)
                } else {
                    ForEach(Array(vm.devices.enumerated()), id: \.element.id) { idx, d in
                        deviceRow(d, isCurrent: d.id == vm.currentDevice)
                        if idx < vm.devices.count - 1 {
                            Divider().background(Palette.line)
                        }
                    }
                }
            }
        }
        .confirmationDialog("Sign this device out?",
                            isPresented: Binding(get: { revokeTarget != nil },
                                                 set: { if !$0 { revokeTarget = nil } }),
                            titleVisibility: .visible) {
            if let target = revokeTarget {
                Button("Sign out", role: .destructive) {
                    let id = target.id; revokeTarget = nil
                    Task { await vm.revoke(id) }
                }
            }
            Button("Cancel", role: .cancel) { revokeTarget = nil }
        } message: {
            Text(revokeTarget?.id == vm.currentDevice
                 ? "This is the device you're using — signing it out will sign you out of Snapceipt."
                 : "That device will need to sign in again.")
        }
    }

    @ViewBuilder private func deviceRow(_ d: DeviceDTO, isCurrent: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(deviceTitle(d)).font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                    if isCurrent {
                        Text("This device").font(.ui(11, .semibold)).foregroundStyle(accent.deep)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(accent.soft, in: Capsule())
                    }
                }
                Text(deviceSubtitle(d)).font(.ui(12, .regular)).foregroundStyle(Palette.ink3)
            }
            Spacer(minLength: 8)
            Button("Sign out") { revokeTarget = d }
                .font(.ui(13, .semibold)).foregroundStyle(Palette.alert)
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.accountRevokePrefix + d.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.accountDeviceRowPrefix + d.id)
    }

    // MARK: - Danger zone

    @ViewBuilder private func dangerZone(_ vm: AccountViewModel) -> some View {
        groupLabel("Danger zone")
        Card {
            VStack(alignment: .leading, spacing: 14) {
                if !showDelete {
                    Button {
                        confirmText = ""
                        showDelete = true
                    } label: {
                        HStack {
                            Text("Delete account").font(.ui(14.5, .semibold)).foregroundStyle(Palette.alert)
                            Spacer()
                            Icon(name: "chevR", size: 16, color: Palette.alert)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AccessibilityID.accountDeleteButton)
                } else {
                    Text("This permanently deletes your account and all receipts. Type DELETE to confirm.")
                        .font(.ui(12.5, .regular)).foregroundStyle(Palette.ink2)
                    TextField("DELETE", text: $confirmText)
                        .autocorrectionDisabled().textInputAutocapitalization(.characters)
                        .padding(12).background(Palette.paper2, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier(AccessibilityID.accountDeleteConfirmField)
                    HStack(spacing: 10) {
                        Button("Cancel") { showDelete = false; confirmText = "" }
                            .font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink2)
                            .buttonStyle(.plain)
                        Spacer()
                        Button("Delete account", role: .destructive) {
                            Task { await vm.deleteAccount() }
                        }
                        .font(.ui(14.5, .semibold))
                        .foregroundStyle(confirmText == "DELETE" ? Palette.alert : Palette.ink3)
                        .buttonStyle(.plain)
                        .disabled(confirmText != "DELETE")
                        .accessibilityIdentifier(AccessibilityID.accountDeleteConfirmButton)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func deviceTitle(_ d: DeviceDTO) -> String {
        d.model ?? d.platform?.capitalized ?? "Device"
    }
    private func deviceSubtitle(_ d: DeviceDTO) -> String {
        var parts: [String] = []
        if let p = d.platform { parts.append(p.uppercased()) }
        if let os = d.osVersion { parts.append(os) }
        if parts.isEmpty { parts.append(d.id) }
        return parts.joined(separator: " · ")
    }

    private func groupLabel(_ s: String) -> some View {
        Text(s).font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
    }
}
