import Foundation

/// Pure quiet-hours encoding for the Notifications settings screen. The cron enforces
/// the wrap-around window (§4.6); here we only convert picker components <-> minutes and
/// build the PUT /devices/me body. No hidden Date()/TimeZone.current in the math.
enum QuietHours {
    /// Minutes-from-midnight (0...1439) for the given clock components, clamped.
    static func minutes(hour: Int, minute: Int) -> Int {
        let raw = hour * 60 + minute
        return Swift.min(1439, Swift.max(0, raw))
    }

    /// (hour, minute) for minutes-from-midnight.
    static func components(fromMinutes m: Int) -> (hour: Int, minute: Int) {
        let clamped = Swift.min(1439, Swift.max(0, m))
        return (clamped / 60, clamped % 60)
    }

    /// The device's IANA timezone (e.g. "Australia/Sydney").
    static func deviceTimezone(_ tz: TimeZone = .current) -> String { tz.identifier }

    /// Assemble the PUT /devices/me body for a settings change. `apnsToken` is left nil —
    /// token updates come only from the registration path (Task 8), never settings.
    static func updateBody(pushEnabled: Bool?, quietStartMin: Int?, quietEndMin: Int?,
                           timezone: String) -> UpdateDeviceBody {
        UpdateDeviceBody(apnsToken: nil, quietHoursStartMin: quietStartMin,
                         quietHoursEndMin: quietEndMin, timezone: timezone, pushEnabled: pushEnabled)
    }
}
