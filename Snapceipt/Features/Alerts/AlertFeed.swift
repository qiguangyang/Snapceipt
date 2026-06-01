import Foundation

/// Pure derivation of the AlertsSheet feed (§4.7): an item per budget alerted in the
/// current month whose live spend is at/over its threshold. `now` is INJECTED.
enum AlertFeed {
    /// One budget's alert inputs (live spend + the server-set alertSentAt).
    struct Input: Equatable {
        let budgetId: String
        let label: String
        let capCents: Int
        let alertThresholdPct: Int
        var spentCents: Int
        var alertSentAt: Int?
    }

    /// A derived feed item.
    struct Item: Identifiable, Equatable {
        let id: String           // budgetId + "-" + monthKey
        let budgetId: String
        let title: String
        let body: String
        let firedAt: Int         // alertSentAt ms
    }

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()

    private static func monthKey(of msEpoch: Int) -> String {
        let d = Date(timeIntervalSince1970: Double(msEpoch) / 1000.0)
        let c = utcCalendar.dateComponents([.year, .month], from: d)
        return String(format: "%04d-%02d", c.year!, c.month!)
    }

    /// Derive the feed, newest-first. Excludes nil alertSentAt, prior-month sends,
    /// and budgets whose spend is below threshold.
    static func items(inputs: [Input], now: Date) -> [Item] {
        let nowKey = BudgetSpend.monthKey(for: now)
        return inputs.compactMap { inp -> Item? in
            guard let sent = inp.alertSentAt, monthKey(of: sent) == nowKey else { return nil }
            let thresholdCents = inp.capCents * inp.alertThresholdPct / 100
            guard inp.spentCents >= thresholdCents else { return nil }
            // Display the ACTUAL spend percentage — round(spent/cap*100), mirroring the
            // backend push body (budgetAlert.ts) byte-for-byte — so the in-app feed shows
            // the same number as the push the user just tapped (not the trigger threshold).
            let spendPct = inp.capCents > 0
                ? Int((Double(inp.spentCents) / Double(inp.capCents) * 100).rounded())
                : 0
            return Item(
                id: "\(inp.budgetId)-\(nowKey)",
                budgetId: inp.budgetId,
                title: "Budget alert: \(inp.label)",
                body: "\(fmt(inp.spentCents)) of \(fmt(inp.capCents)) (\(spendPct)%)",
                firedAt: sent)
        }
        .sorted { $0.firedAt > $1.firedAt }
    }
}

/// UserDefaults-backed read/dismiss cache for alert items (per-device, NOT synced).
/// Keyed by the item id (which embeds budgetId+monthKey, so month rollover re-arms).
struct AlertCache {
    private let defaults: UserDefaults
    private let readKey = "sc.alerts.read"
    private let dismissedKey = "sc.alerts.dismissed"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func set(_ key: String) -> Set<String> {
        Set((defaults.array(forKey: key) as? [String]) ?? [])
    }
    private func save(_ s: Set<String>, _ key: String) {
        defaults.set(Array(s), forKey: key)
    }

    func isRead(_ id: String) -> Bool { set(readKey).contains(id) }
    func isDismissed(_ id: String) -> Bool { set(dismissedKey).contains(id) }

    mutating func markRead(_ id: String) { var s = set(readKey); s.insert(id); save(s, readKey) }
    mutating func dismiss(_ id: String) { var s = set(dismissedKey); s.insert(id); save(s, dismissedKey) }

    /// Items not dismissed.
    func visible(_ items: [AlertFeed.Item]) -> [AlertFeed.Item] {
        let dis = set(dismissedKey)
        return items.filter { !dis.contains($0.id) }
    }

    /// Count of visible, unread items (drives the Home bell dot).
    func unreadCount(_ items: [AlertFeed.Item]) -> Int {
        let read = set(readKey)
        return visible(items).filter { !read.contains($0.id) }.count
    }
}
