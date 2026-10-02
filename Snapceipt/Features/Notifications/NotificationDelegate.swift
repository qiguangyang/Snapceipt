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
    static var clientReminderCoordinator: ClientReminderRouteCoordinator?
    static var api: APIClient?
    static var timezoneProvider: () -> String = { QuietHours.deviceTimezone() }

    /// The build's APNs environment, reported to the server so it pushes to the matching host.
    /// Debug builds (Xcode/devicectl) have aps-environment=development → SANDBOX tokens; Release
    /// (TestFlight/App Store) → production. `#if DEBUG` mirrors the entitlement files exactly.
    static var apnsEnvironment: String {
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }

    /// Set by SnapceiptApp: refresh app data when an email-in push arrives (SyncEngine.sync()).
    /// A closure seam so the delegate can trigger a sync without holding the whole SyncEngine.
    static var refreshOnPush: (@Sendable () async -> Void)?

    /// Central push routing (testable). email_in → refresh then open the receipt review
    /// editor (fallback to the email-in list when no transactionId); otherwise the existing
    /// budget deep-link / budgetId routing is preserved unchanged.
    @MainActor
    static func route(userInfo: [AnyHashable: Any],
                      router: Router?,
                      refresh: (@Sendable () async -> Void)?,
                      clientReminders: ClientReminderRouteCoordinator? = nil) async {
        if userInfo["type"] as? String == "client_follow_up" {
            if let route = ClientReminderRoute(userInfo: userInfo) { clientReminders?.receive(route) }
            return
        }
        if userInfo["type"] as? String == "email_in" {
            await refresh?()
            if let txn = userInfo["transactionId"] as? String, !txn.isEmpty {
                router?.openEmailInReceipt(txn)
            } else {
                router?.present(.emailIn)
            }
            return
        }
        if let deep = userInfo["deepLink"] as? String, let url = URL(string: deep) {
            router?.handleBudgetDeepLink(url)
        } else if let id = userInfo["budgetId"] as? String {
            router?.openBudget(id)
        }
    }

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
        // Re-uploading the token must NOT re-enable push — leave pushEnabled nil so the server's
        // COALESCE preserves the user's Notifications toggle. (New devices still default to ON via
        // the INSERT's `COALESCE(?, 1)`.) The toggle is the single source of truth for push_enabled;
        // forcing `true` here silently overrode every "off" on the next launch/foreground/register.
        let body = UpdateDeviceBody(apnsToken: token, quietHoursStartMin: nil,
                                    quietHoursEndMin: nil, timezone: Self.timezoneProvider(),
                                    pushEnabled: nil, apnsEnvironment: Self.apnsEnvironment)
        Task { _ = try? await Self.api?.updateDevice(body) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Simulator / no-entitlement path: log and continue. No crash, no UI impact.
        print("APNs registration failed: \(error.localizedDescription)")
    }

    // Tap on a delivered notification -> route (email-in review editor / budget deep-link).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        await Self.route(userInfo: response.notification.request.content.userInfo,
                         router: Self.router, refresh: Self.refreshOnPush, clientReminders: Self.clientReminderCoordinator)
    }

    // Foreground delivery -> show a banner. An email-in push also triggers a sync so the
    // open list refreshes behind the banner; other pushes are unchanged.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if notification.request.content.userInfo["type"] as? String == "email_in" {
            await Self.refreshOnPush?()
        }
        return [.banner, .sound]
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

/// Posted (on the main actor) after an email-in push triggers a sync, so an open
/// EmailInView can re-fetch its inbox and show the just-arrived receipt.
extension Notification.Name {
    static let emailInReceiptArrived = Notification.Name("emailInReceiptArrived")
}
