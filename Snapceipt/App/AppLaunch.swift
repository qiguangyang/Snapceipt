import Foundation
import SwiftData
import UIKit

#if DEBUG
/// Parses UI-test launch arguments/environment to decide how the app wires itself.
/// Every surface here is compiled out of Release builds.
struct AppLaunch {
    let useStub: Bool
    let reset: Bool
    let seed: Bool
    let apiBaseURLOverride: URL?

    init(arguments: [String] = ProcessInfo.processInfo.arguments,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        useStub = arguments.contains("-uiTestStub")
        reset = arguments.contains("-uiTestReset")
        seed = arguments.contains("-uiTestSeed")
        apiBaseURLOverride = environment["API_BASE_URL"].flatMap(URL.init(string:))
    }

    static let current = AppLaunch()

    /// Clears dev-namespaced auth + active-profile + sync-cursor state so a UI test starts signed-out + empty.
    func applyResetIfNeeded(authStore: AuthStore) {
        guard reset else { return }
        authStore.clear()
        UserDefaults.standard.removeObject(forKey: "sc.activeProfile")
        UserDefaults.standard.removeObject(forKey: "sc.syncCursor")
    }

    /// Seeds an already-signed-in dev session + two profiles, for shell-level UI tests
    /// where the profile switcher must be enabled (needs >1 profile). DEBUG only.
    func applySeedIfNeeded(authStore: AuthStore, context: ModelContext) {
        guard seed else { return }
        authStore.save(SessionResponse(
            accessToken: "seed-access", refreshToken: "seed-refresh", expiresIn: 900,
            user: SessionUser(id: DevAccount.userId, email: DevAccount.email, displayName: "Dev")))
        let p1 = Profile(userId: DevAccount.userId, name: "Studio North", type: "business",
                         initials: "SN", accent1: "#0E7C72", accent2: "#DCF0ED", accent3: "#0A5950",
                         sortOrder: 0, isDefault: true)
        let p2 = Profile(userId: DevAccount.userId, name: "Home Budget", type: "personal",
                         initials: "HB", accent1: "#E8602C", accent2: "#FDEBE0", accent3: "#C2461A",
                         sortOrder: 1, isDefault: false)
        context.insert(p1); context.insert(p2)
        // Seed a handful of transactions on the business profile so Reports renders
        // a real donut/net/pills under -uiTestSeed. Dates anchored to the current month
        // so the default Month period shows them.
        let cal: Calendar = {
            var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
        }()
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        let isoFmt: DateFormatter = {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"; return f
        }()
        func dayISO(_ d: Int) -> String { isoFmt.string(from: cal.date(byAdding: .day, value: d, to: monthStart)!) }
        context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, catKey: "income",
                                   amountCents: 500_00, txnDate: dayISO(1)))
        context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, merchant: "The Grounds",
                                   catKey: "meals", amountCents: -120_00, txnDate: dayISO(3),
                                   deductiblePct: 50, gstCents: 10_91))
        context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, merchant: "BP",
                                   catKey: "fuel", amountCents: -80_00, txnDate: dayISO(5),
                                   deductiblePct: 100, gstCents: 7_27))
        context.insert(VehicleYear(userId: DevAccount.userId, profileId: p1.id, vehicleId: "v1",
                                   fyStartYear: FinancialYear.of(Date(), startMonth: 7).startYear, claimCents: 250_00))
        // F3: seed budgets on p1 (active under -uiTestSeed).
        // 1) whole-profile budget WELL OVER cap (the seeded -120 + -80 = 200 > 150 cap -> red).
        let overBudget = Budget(userId: DevAccount.userId, profileId: p1.id, categoryId: nil,
                                label: "Whole profile", capCents: 150_00, alertThresholdPct: 90)
        context.insert(overBudget)
        // 2) a meals budget UNDER cap (200 spent of 600).
        context.insert(Budget(userId: DevAccount.userId, profileId: p1.id, categoryId: nil,
                              label: "Dining", capCents: 600_00, alertThresholdPct: 90))
        // 3) an ALREADY-ALERTED budget this month (alertSentAt = now) over threshold -> AlertsSheet item.
        let alerted = Budget(userId: DevAccount.userId, profileId: p1.id, categoryId: nil,
                             label: "Coffee", capCents: 100_00, alertThresholdPct: 90,
                             alertSentAt: Epoch.nowMs())
        context.insert(alerted)
        // give "Coffee" enough spend to be at/over threshold (>= 90 of 100): add a -95 txn this month.
        context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, merchant: "Cafe",
                                   catKey: "meals", amountCents: -95_00, txnDate: dayISO(2)))
        try? context.save()
    }

    func makeAPIClient(auth: AuthStore) -> APIClient {
        if useStub { return StubAPIClient() }
        let base = apiBaseURLOverride ?? URL(string: "https://api.snapceipt.app")!
        return LiveAPIClient(baseURL: base, auth: auth)
    }

    func makeContainer() -> ModelContainer {
        makeSnapceiptContainer(inMemory: useStub)
    }

    /// Canned (image, rawText) for the camera-less capture UI test. Loaded from the
    /// app bundle when `-uiTestStub` is set; nil otherwise (production uses the camera).
    var cannedScan: (image: UIImage, rawText: String)? {
        guard useStub,
              let url = Bundle.main.url(forResource: "canned-receipt", withExtension: "jpg"),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return nil }
        let rawText = "THE GROUNDS\n28/05/2026\nFlat White x2  9.00\nBig Brekkie 24.00\nGST 3.86\nTOTAL 42.50"
        return (image, rawText)
    }
}
#endif
