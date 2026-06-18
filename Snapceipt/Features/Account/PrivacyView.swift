import SwiftUI

/// Privacy & security screen (F7, spec §6). A single biometric app-lock toggle
/// bound to the shared `AppLockController`: turning it on requires a successful
/// `LAContext` check first (`setEnabled` refuses if it fails), and the toggle is
/// disabled with an explanatory caption when the device can't do biometry/passcode
/// auth (`!appLock.isAvailable`). Mirrors the shared settings chrome (cream
/// background, `SheetHeader`, uppercase group labels, grouped `Card`s, an
/// income-track toggle and a paper-2 info note).
struct PrivacyView: View {
    let appLock: AppLockController
    let onClose: () -> Void

    @Environment(\.accent) private var accent

    var body: some View {
        ZStack {
            Palette.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                SheetHeader(title: "Privacy & security", onClose: onClose)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        groupLabel("App lock")
                        Card {
                            HStack(spacing: 12) {
                                IconCircle(name: "lock", tint: accent.base, soft: accent.soft,
                                           size: 38, iconSize: 19)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Require Face ID / Touch ID")
                                        .font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                                    Text("Unlock to open Snapceipt")
                                        .font(.ui(12, .regular)).foregroundStyle(Palette.ink3)
                                }
                                Spacer(minLength: 8)
                                Toggle("", isOn: Binding(
                                    get: { appLock.isEnabled },
                                    set: { on in Task { await appLock.setEnabled(on) } }))
                                    .labelsHidden()
                                    .tint(Palette.income)
                                    .disabled(!appLock.isAvailable)
                                    .accessibilityIdentifier(AccessibilityID.privacyAppLockToggle)
                            }
                        }
                        infoNote(
                            icon: appLock.isAvailable ? "info" : "lock",
                            appLock.isAvailable
                                ? "Snapceipt will lock when you leave the app and ask for Face ID / Touch ID to return."
                                : "Set up Face ID / a device passcode to use this.")
                    }
                    .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 60)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.privacyScreen)
        .transition(.opacity)
    }

    // MARK: - Shared chrome

    private func groupLabel(_ s: String) -> some View {
        Text(s).font(.ui(12.5, .bold)).tracking(0.3).foregroundStyle(Palette.ink3)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
    }

    private func infoNote(icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Icon(name: icon, size: 16, color: Palette.ink3)
                .padding(.top, 1)
            Text(text).font(.ui(12.5, .regular)).foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Palette.paper2, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
    }
}
