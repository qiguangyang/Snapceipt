import Foundation
import Observation

/// Notification settings state + persistence. Push on/off + quiet hours persist locally
/// (UserDefaults) AND push to the backend via PUT /devices/me (QuietHours.updateBody).
/// The BAS-reminder toggle is a LOCAL placeholder (no backend in v1). Deps injected.
@Observable
@MainActor
final class NotificationsSettingsViewModel {
    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let timezone: String

    var pushEnabled: Bool { didSet { defaults.set(pushEnabled, forKey: Keys.push) } }
    var quietHoursEnabled: Bool { didSet { defaults.set(quietHoursEnabled, forKey: Keys.quietOn) } }
    var quietStartMin: Int { didSet { defaults.set(quietStartMin, forKey: Keys.quietStart) } }
    var quietEndMin: Int { didSet { defaults.set(quietEndMin, forKey: Keys.quietEnd) } }
    var basReminderEnabled: Bool { didSet { defaults.set(basReminderEnabled, forKey: Keys.bas) } }

    private enum Keys {
        static let push = "sc.notif.push"
        static let quietOn = "sc.notif.quietOn"
        static let quietStart = "sc.notif.quietStart"
        static let quietEnd = "sc.notif.quietEnd"
        static let bas = "sc.notif.bas"
    }

    init(api: APIClient, defaults: UserDefaults = .standard,
         timezone: String = QuietHours.deviceTimezone()) {
        self.api = api
        self.defaults = defaults
        self.timezone = timezone
        self.pushEnabled = defaults.object(forKey: Keys.push) as? Bool ?? true
        self.quietHoursEnabled = defaults.object(forKey: Keys.quietOn) as? Bool ?? false
        self.quietStartMin = defaults.object(forKey: Keys.quietStart) as? Int ?? 1320 // 22:00
        self.quietEndMin = defaults.object(forKey: Keys.quietEnd) as? Int ?? 420       // 07:00
        self.basReminderEnabled = defaults.object(forKey: Keys.bas) as? Bool ?? false
    }

    /// Push the current state to the backend. Quiet-hours minutes are nil when disabled.
    func persist() async {
        let body = QuietHours.updateBody(
            pushEnabled: pushEnabled,
            quietStartMin: quietHoursEnabled ? quietStartMin : nil,
            quietEndMin: quietHoursEnabled ? quietEndMin : nil,
            timezone: timezone)
        _ = try? await api.updateDevice(body)
    }
}
