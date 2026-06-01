import Testing
import Foundation
import SwiftData
@testable import Snapceipt

@Suite("AlertFeed + cache")
struct AlertFeedTests {
    private func ms(_ s: String) -> Int {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return Int(f.date(from: s)!.timeIntervalSince1970 * 1000)
    }
    private func date(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }

    /// A budget alerted this month, spend over its threshold.
    private func alerted() -> AlertFeed.Input {
        AlertFeed.Input(budgetId: "b1", label: "Meals", capCents: 100_00,
                        alertThresholdPct: 90, spentCents: 95_00, alertSentAt: ms("2026-06-10"))
    }

    @Test("a budget alerted this month over threshold yields a feed item")
    func fires() {
        let items = AlertFeed.items(inputs: [alerted()], now: date("2026-06-15"))
        #expect(items.count == 1)
        #expect(items[0].id == "b1-2026-06")
        #expect(items[0].title == "Budget alert: Meals")
        #expect(items[0].body == "$95.00 of $100.00 (95%)")  // actual spend %, mirrors the push body
        #expect(items[0].firedAt == ms("2026-06-10"))
    }

    @Test("alertSentAt in a prior month is excluded")
    func priorMonthExcluded() {
        var inp = alerted(); inp.alertSentAt = ms("2026-05-31")
        #expect(AlertFeed.items(inputs: [inp], now: date("2026-06-15")).isEmpty)
    }

    @Test("nil alertSentAt or spend below threshold is excluded")
    func notFired() {
        var noSent = alerted(); noSent.alertSentAt = nil
        var lowSpend = alerted(); lowSpend.spentCents = 10_00
        #expect(AlertFeed.items(inputs: [noSent, lowSpend], now: date("2026-06-15")).isEmpty)
    }

    @Test("items newest-first by firedAt")
    func ordering() {
        let a = AlertFeed.Input(budgetId: "a", label: "A", capCents: 100, alertThresholdPct: 50,
                                spentCents: 100, alertSentAt: ms("2026-06-02"))
        let b = AlertFeed.Input(budgetId: "b", label: "B", capCents: 100, alertThresholdPct: 50,
                                spentCents: 100, alertSentAt: ms("2026-06-20"))
        let items = AlertFeed.items(inputs: [a, b], now: date("2026-06-15"))
        #expect(items.map(\.id) == ["b-2026-06", "a-2026-06"])
    }

    @Test("cache marks read + dismissed; dismissed excluded; unread counted")
    func cacheLogic() {
        let suiteName = "sc.test.alerts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        var cache = AlertCache(defaults: defaults)
        let items = AlertFeed.items(inputs: [alerted()], now: date("2026-06-15"))
        #expect(cache.unreadCount(items) == 1)
        cache.markRead("b1-2026-06")
        #expect(cache.unreadCount(items) == 0)
        cache.dismiss("b1-2026-06")
        #expect(cache.visible(items).isEmpty)
        // Persisted across instances on the same suite.
        let reopened = AlertCache(defaults: defaults)
        #expect(reopened.isDismissed("b1-2026-06"))
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
@Suite("AlertsViewModel")
struct AlertsViewModelTests {
    private func ms(_ s: String) -> Int {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return Int(f.date(from: s)!.timeIntervalSince1970 * 1000)
    }
    private func date(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }

    @Test("derives feed from an alerted over-threshold budget; dismiss removes it")
    func deriveAndDismiss() throws {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        let ctx = ModelContext(container)
        let b = Budget(userId: "u1", profileId: "p1", categoryId: nil, label: "All",
                       capCents: 100_00, alertThresholdPct: 90, alertSentAt: ms("2026-06-10"))
        ctx.insert(b)
        ctx.insert(Transaction(userId: "u1", profileId: "p1", catKey: "meals",
                               amountCents: -95_00, txnDate: "2026-06-03"))
        try ctx.save()
        let suiteName = "sc.test.alertsvm.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let vm = AlertsViewModel(context: ctx, userId: "u1", profileId: "p1",
                                 now: date("2026-06-15"), cache: AlertCache(defaults: defaults))
        #expect(vm.items.count == 1)
        let id = vm.items[0].id
        vm.dismiss(id)
        #expect(vm.items.isEmpty)
        defaults.removePersistentDomain(forName: suiteName)  // clean up by SUITE name, not .description
    }
}
