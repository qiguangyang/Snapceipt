import SwiftUI
import AVFoundation
import UserNotifications
import UIKit

/// A primed system permission, with the rationale copy shown before the real prompt.
enum PermissionKind: Equatable {
    case camera, notifications

    var title: String {
        switch self {
        case .camera: return "Snap receipts in a tap"
        case .notifications: return "Stay on top of your budgets"
        }
    }
    var rationale: String {
        switch self {
        case .camera:
            return "Snapceipt uses your camera to capture receipts and read the total, GST and category for you. Photos stay on your device until you save."
        case .notifications:
            return "Get a heads-up when a budget is close to its cap or your BAS is due. You can fine-tune these later in Settings."
        }
    }
    var systemImage: String {
        switch self {
        case .camera: return "camera.fill"
        case .notifications: return "bell.badge.fill"
        }
    }
    var allowTitle: String {
        switch self {
        case .camera: return "Allow camera access"
        case .notifications: return "Turn on notifications"
        }
    }
}

/// Abstraction over the system permission prompts so the UI is injectable + buildable in previews.
protocol PermissionRequesting {
    func request(_ kind: PermissionKind) async
}

/// Performs the real `AVCaptureDevice` + `UNUserNotificationCenter` permission requests.
struct LivePermissionRequester: PermissionRequesting {
    func request(_ kind: PermissionKind) async {
        switch kind {
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        case .notifications:
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            // Granting authorization is NOT enough to receive push: we must also
            // register for a remote (APNs) token, which uploads via the delegate's
            // didRegisterForRemoteNotificationsWithDeviceToken -> updateDevice path.
            if granted {
                await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
            }
        }
    }
}

/// Rationale + "Allow" CTA for a single permission. Tapping Allow runs the injected
/// requester then advances via `onContinue`; "Not now" skips straight to `onContinue`.
struct PermissionPrimingView: View {
    let kind: PermissionKind
    let requester: PermissionRequesting
    let onContinue: () -> Void

    @Environment(\.accent) private var accent
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            ZStack {
                Circle().fill(accent.soft).frame(width: 110, height: 110)
                Image(systemName: kind.systemImage)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(accent.base)
            }
            .padding(.bottom, 26)

            Text(kind.title)
                .font(.display(24, .bold))
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
                .padding(.bottom, 10)

            Text(kind.rationale)
                .font(.ui(15))
                .foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 34)

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                Button(action: allow) {
                    Text(kind.allowTitle)
                        .font(.ui(16, .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(accent.base, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .disabled(busy)

                Button(action: onContinue) {
                    Text("Not now")
                        .font(.ui(15, .semibold))
                        .foregroundStyle(Palette.ink2)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream.ignoresSafeArea())
    }

    private func allow() {
        busy = true
        Task {
            await requester.request(kind)
            busy = false
            onContinue()
        }
    }
}

#if DEBUG
/// No-op requester used by previews + the onboarding preview so nothing prompts.
struct NoopPermissionRequester: PermissionRequesting {
    func request(_ kind: PermissionKind) async {}
}

#Preview {
    PermissionPrimingView(kind: .camera, requester: NoopPermissionRequester()) {}
        .environment(\.accent, .personal)
}
#endif
