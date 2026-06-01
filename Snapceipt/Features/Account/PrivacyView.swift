import SwiftUI

/// Privacy & security screen (F7, spec §6). A single biometric app-lock toggle
/// bound to the shared `AppLockController`: turning it on requires a successful
/// `LAContext` check first (`setEnabled` refuses if it fails), and the toggle is
/// disabled with an explanatory caption when the device can't do biometry/passcode
/// auth (`!appLock.isAvailable`). Mirrors `NotificationsSettingsView` chrome.
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
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                Toggle("Require Face ID / Touch ID to unlock", isOn: Binding(
                                    get: { appLock.isEnabled },
                                    set: { on in Task { await appLock.setEnabled(on) } }))
                                    .font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                                    .tint(accent.base)
                                    .disabled(!appLock.isAvailable)
                                    .accessibilityIdentifier(AccessibilityID.privacyAppLockToggle)
                                if !appLock.isAvailable {
                                    Text("Set up Face ID / a device passcode to use this.")
                                        .font(.ui(12.5, .regular)).foregroundStyle(Palette.ink3)
                                } else {
                                    Text("Snapceipt will lock when you leave the app and ask for Face ID / Touch ID to return.")
                                        .font(.ui(12.5, .regular)).foregroundStyle(Palette.ink3)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 60)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.privacyScreen)
        .transition(.opacity)
    }
}
