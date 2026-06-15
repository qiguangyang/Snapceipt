import UIKit
import UserNotifications

/// App delegate bridging APNs token registration + notification taps into the app.
/// Wired via @UIApplicationDelegateAdaptor. The Router + APIClient + AuthStore are
/// injected from SnapceiptApp.init (UIKit instantiates the adaptor, so we use shared
/// references rather than init params). The simulator never issues a real token, so
/// didFailToRegister just logs — real push is verified by the backend unit tests.
final class NotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Shared injection points set by SnapceiptApp before the scene appears.
    static var router: Router?
    static var api: APIClient?
    static var timezoneProvider: () -> String = { QuietHours.deviceTimezone() }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Re-register on every cold launch IF the user already authorized notifications,
        // so a rotated APNs token re-uploads via didRegisterForRemoteNotifications.
        Task { await Self.registerIfAuthorized() }
        return true
    }

    /// Register for remote notifications only when authorization is already granted, so a
    /// previously-granted user re-uploads a (possibly rotated) token on launch without
    /// re-prompting. No-op when not authorized.
    @MainActor
    static func registerIfAuthorized() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .authorized {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Lowercase hex of a device token, no separators (the apns token wire format).
    static func hexToken(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = Self.hexToken(deviceToken)
        UserDefaults.standard.set(token, forKey: "sc.apnsToken")
        let body = UpdateDeviceBody(apnsToken: token, quietHoursStartMin: nil,
                                    quietHoursEndMin: nil, timezone: Self.timezoneProvider(),
                                    pushEnabled: true)
        Task { _ = try? await Self.api?.updateDevice(body) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Simulator / no-entitlement path: log and continue. No crash, no UI impact.
        print("APNs registration failed: \(error.localizedDescription)")
    }

    // Tap on a delivered notification -> deep-link to the budget.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        await MainActor.run {
            if let deep = info["deepLink"] as? String, let url = URL(string: deep) {
                Self.router?.handleBudgetDeepLink(url)
            } else if let id = info["budgetId"] as? String {
                Self.router?.openBudget(id)
            }
        }
    }

    // Foreground delivery -> show a banner.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Request authorization and, if granted, register for remote notifications. Safe to
    /// call repeatedly. No-op token on the simulator (didFailToRegister handles it).
    @MainActor
    static func requestAndRegister() async {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        if granted { UIApplication.shared.registerForRemoteNotifications() }
    }
}
