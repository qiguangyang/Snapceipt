import SwiftUI

/// Month-key helpers shared by the Quotes + Invoices date filters (mirrors the Activity page's
/// month menu). A key is `""` (= All time) or `"YYYY-MM"`. The pure-string keys prefix-match the
/// UTC `"YYYY-MM-DD"` dates the lists already key off (`ExportDateFormatter`), so there's no
/// Date-window math — the same model the Activity filter uses.
enum MonthKey {
    static let allTime = ""

    /// `"YYYY-MM-DD"` for an epoch-ms instant in the DEVICE's local timezone (`TimeZone.current`),
    /// so the month filter reflects the user's own calendar rather than UTC.
    static func localDay(_ epochMs: Int) -> String {
        localDayFormatter.string(from: Date(timeIntervalSince1970: Double(epochMs) / 1000.0))
    }
    private static let localDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        // No `timeZone` set → the formatter uses the device's current timezone.
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Current month `"YYYY-MM"` in the device's local timezone.
    static var current: String { String(localDayFormatter.string(from: Date()).prefix(7)) }

    /// Human label for a `"YYYY-MM"` key (e.g. "Jun 2026"); reuses the Activity formatter.
    static func label(_ key: String) -> String { ActivityDate.monthLabel(key) }

    /// True when `dayString` (`"YYYY-MM-DD"`) falls in `key` (`"YYYY-MM"`); an empty key = All time.
    static func matches(_ dayString: String, _ key: String) -> Bool {
        key.isEmpty || dayString.hasPrefix(key)
    }

    /// Distinct months present in `dayStrings`, PLUS the current month (so the default month is
    /// always selectable even with no data), newest first.
    static func available(_ dayStrings: [String]) -> [String] {
        var keys = Set(dayStrings.map { String($0.prefix(7)) })
        keys.insert(current)
        return keys.sorted(by: >)
    }

    /// Newest month that actually has data (max key), or nil — used to land the list on recent
    /// data on open (like Activity), without polluting it with the always-inserted current month.
    static func newest(_ dayStrings: [String]) -> String? {
        dayStrings.map { String($0.prefix(7)) }.max()
    }
}

/// The month-picker menu used by the Quotes + Invoices lists — same look + behaviour as the
/// Activity page's date filter (a `Menu` with "All time" + every month that has data, newest first).
struct MonthFilterMenu: View {
    @Binding var selection: String        // "" = All time, else "YYYY-MM"
    let availableKeys: [String]           // months present (+ current), newest first
    let accessibilityID: String
    @Environment(\.accent) private var accent

    var body: some View {
        Menu {
            Button { selection = MonthKey.allTime } label: { item("All time", MonthKey.allTime) }
            ForEach(availableKeys, id: \.self) { key in
                Button { selection = key } label: { item(MonthKey.label(key), key) }
            }
        } label: {
            HStack(spacing: 7) {
                Icon(name: "calendar", size: 18, color: accent.base)
                Text(selection.isEmpty ? "All time" : MonthKey.label(selection))
                    .font(.ui(13.5, .bold)).foregroundStyle(Palette.ink)
                Icon(name: "chevD", size: 15, color: Palette.ink3)
            }
            .frame(height: 42).padding(.horizontal, 13)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
            .cardShadow()
        }
        .accessibilityIdentifier(accessibilityID)
    }

    @ViewBuilder private func item(_ title: String, _ key: String) -> some View {
        if key == selection { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}
