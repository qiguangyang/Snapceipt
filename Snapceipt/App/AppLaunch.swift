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
    let tour: Bool
    let tourEmpty: Bool
    let apiBaseURLOverride: URL?

    init(arguments: [String] = ProcessInfo.processInfo.arguments,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        useStub = arguments.contains("-uiTestStub")
        reset = arguments.contains("-uiTestReset")
        seed = arguments.contains("-uiTestSeed")
        tour = arguments.contains("-uiTestTour")
        tourEmpty = arguments.contains("-uiTestTourEmpty")
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
        // F4: seed loyalty cards on p1 (active under -uiTestSeed): one EAN-13 + one QR.
        context.insert(LoyaltyCard(userId: DevAccount.userId, profileId: p1.id,
                                   brand: "Everyday Rewards", subBrand: "Woolworths",
                                   number: "5901234123457", barcodeFormat: "ean13",
                                   pointsLabel: "1,240 pts",
                                   color1: "#1A8A3C", color2: "#0C5C26", sortOrder: 0))
        context.insert(LoyaltyCard(userId: DevAccount.userId, profileId: p1.id,
                                   brand: "Qantas FF", subBrand: nil,
                                   number: "QF1234567", barcodeFormat: "qr",
                                   pointsLabel: nil,
                                   color1: "#E40000", color2: "#A30000", sortOrder: 1))
        // F5: seed a saved client + a draft quote (+ one line item) on p1 (active business).
        let client = Client(userId: DevAccount.userId, profileId: p1.id,
                            name: "Acme Pty Ltd", email: "accounts@acme.example")
        context.insert(client)
        let quote = Quote(userId: DevAccount.userId, profileId: p1.id,
                          clientName: "Northbridge Cafe", clientEmail: "owner@northbridge.example",
                          gstEnabled: true, subtotalCents: 200_00, gstCents: 20_00, totalCents: 220_00,
                          status: "draft")
        context.insert(quote)
        context.insert(QuoteLineItem(userId: DevAccount.userId, quoteId: quote.id,
                                     itemDescription: "Brand identity package", quantity: 1,
                                     unitPriceCents: 200_00, sortOrder: 0))
        // F6: two email-in receipts on the business profile — one failed (needs review),
        // one done — so EmailInUITests can exercise the failed-first list + review flow.
        context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, merchant: "",
                                   catKey: "office", amountCents: 0, txnDate: dayISO(4),
                                   isAi: true, source: "email_in", extractionStatus: "failed"))
        context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, merchant: "Officeworks",
                                   catKey: "office", amountCents: -45_00, txnDate: dayISO(2),
                                   isAi: true, gstCents: 4_09, source: "email_in", extractionStatus: "done"))
        try? context.save()
    }

    /// Tour-only fixture: a superset of the seed fixture, populated on BOTH
    /// profiles, with months spread, a real Vehicle + trips, WFH logs, a smart
    /// rule, and a SENT quote — so `ScreenshotTourUITests` can shoot every
    /// populated state on each accent. Selected by `-uiTestTour` (independent of
    /// `-uiTestSeed`, which 11 existing classes still depend on unchanged).
    func applyTourSeedIfNeeded(authStore: AuthStore, context: ModelContext) {
        guard tour else { return }
        // Pin the clock to a fixed instant so seeded dates + every Epoch.nowMs()
        // timestamp (budget alertSentAt, quote sentAt) AND the view-layer "now"
        // seams (Epoch.now(), wired in Task 3) are deterministic across tour runs
        // (15 Jan 2026 12:00:00 UTC). Requires Epoch.override, added in Task 3 —
        // so Task 3 is executed BEFORE this task (see ordering note above).
        Epoch.override = 1_768_478_400_000
        authStore.save(SessionResponse(
            accessToken: "tour-access", refreshToken: "tour-refresh", expiresIn: 900,
            user: SessionUser(id: DevAccount.userId, email: DevAccount.email, displayName: "Dev")))
        let p1 = Profile(userId: DevAccount.userId, name: "Studio North", type: "business",
                         initials: "SN", accent1: "#0E7C72", accent2: "#DCF0ED", accent3: "#0A5950",
                         sortOrder: 0, isDefault: true)
        let p2 = Profile(userId: DevAccount.userId, name: "Home Budget", type: "personal",
                         initials: "HB", accent1: "#E8602C", accent2: "#FDEBE0", accent3: "#C2461A",
                         sortOrder: 1, isDefault: false)
        context.insert(p1); context.insert(p2)

        let cal: Calendar = {
            var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
        }()
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: Epoch.now()))!
        let isoFmt: DateFormatter = {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"; return f
        }()
        func dayISO(_ d: Int) -> String { isoFmt.string(from: cal.date(byAdding: .day, value: d, to: monthStart)!) }

        // --- p1 (business) — transactions across categories + months ---
        context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, catKey: "income",
                                   amountCents: 500_00, txnDate: dayISO(1)))
        context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, merchant: "The Grounds",
                                   catKey: "meals", amountCents: -120_00, txnDate: dayISO(3),
                                   deductiblePct: 50, gstCents: 10_91))
        context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, merchant: "BP",
                                   catKey: "fuel", amountCents: -80_00, txnDate: dayISO(5),
                                   deductiblePct: 100, gstCents: 7_27))
        context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, merchant: "Adobe",
                                   catKey: "software", amountCents: -29_99, txnDate: dayISO(-30),
                                   deductiblePct: 100, gstCents: 2_72))
        context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, merchant: "Cafe",
                                   catKey: "meals", amountCents: -95_00, txnDate: dayISO(2)))

        // budgets on p1: over-cap (red), under-cap, and already-alerted
        context.insert(Budget(userId: DevAccount.userId, profileId: p1.id, categoryId: nil,
                              label: "Whole profile", capCents: 150_00, alertThresholdPct: 90))
        context.insert(Budget(userId: DevAccount.userId, profileId: p1.id, categoryId: nil,
                              label: "Dining", capCents: 600_00, alertThresholdPct: 90))
        context.insert(Budget(userId: DevAccount.userId, profileId: p1.id, categoryId: nil,
                              label: "Coffee", capCents: 100_00, alertThresholdPct: 90,
                              alertSentAt: Epoch.nowMs()))

        // logbook: a real Vehicle (so make/model render) + an active logbook window + two trips.
        // CRITICAL: pin the Vehicle's id to "v1" so the VehicleYear + both MileageTrips
        // (which reference vehicleId: "v1") resolve. Vehicle.init defaults id to a random
        // uuidv7 (Vehicle.swift:30), and MileageViewModel joins VehicleYear by
        // `$0.vehicleId == vehicle.id` (MileageViewModel.swift:136) — a dangling "v1" would
        // render the costs/claim card EMPTY and starve the Area 6 audit. Vehicle.init
        // accepts an explicit `id:` (Vehicle.swift:30).
        context.insert(Vehicle(id: "v1", userId: DevAccount.userId, profileId: p1.id,
                               make: "Toyota", model: "HiLux", engineCc: 2800, registration: "ABC123",
                               logbookStartDate: dayISO(-60), logbookEndDate: dayISO(24), businessUsePct: 72))
        context.insert(VehicleYear(userId: DevAccount.userId, profileId: p1.id, vehicleId: "v1",
                                   fyStartYear: FinancialYear.of(Epoch.now(), startMonth: 7).startYear,
                                   claimCents: 250_00))
        context.insert(MileageTrip(userId: DevAccount.userId, profileId: p1.id, tripDate: dayISO(-2),
                                   fromLabel: "Office", toLabel: "Northbridge site", purpose: "Client visit",
                                   distanceM: 18_400, isBusiness: true, claimCents: 14_72,
                                   vehicleId: "v1", odometerStartM: 51_200_000, odometerEndM: 51_218_400))
        context.insert(MileageTrip(userId: DevAccount.userId, profileId: p1.id, tripDate: dayISO(-9),
                                   fromLabel: "Home", toLabel: "Supplier", purpose: "Pickup",
                                   distanceM: 6_100, isBusiness: true, claimCents: 4_88,
                                   vehicleId: "v1", odometerStartM: 51_180_000, odometerEndM: 51_186_100))
        // WFH logs across two weeks RELATIVE TO THE FROZEN NOW (15 Jan 2026, a
        // Thursday): dayISO is monthStart-relative, so dayISO(13) = 14 Jan
        // ("yesterday", inside the frozen Mon 12 – Sun 18 Jan week → the
        // "this week" BarPair renders a non-zero Wednesday bar, the Task 6
        // Step 4b gate) and dayISO(6) = 7 Jan (prior week).
        context.insert(WFHLog(userId: DevAccount.userId, profileId: p1.id, logDate: dayISO(13),
                              minutes: 480, note: "Admin + quotes", rateCentsPerHour: 70, claimCents: 5_60))
        context.insert(WFHLog(userId: DevAccount.userId, profileId: p1.id, logDate: dayISO(6),
                              minutes: 300, rateCentsPerHour: 70, claimCents: 3_50))

        // loyalty: two formats
        context.insert(LoyaltyCard(userId: DevAccount.userId, profileId: p1.id,
                                   brand: "Everyday Rewards", subBrand: "Woolworths",
                                   number: "5901234123457", barcodeFormat: "ean13",
                                   pointsLabel: "1,240 pts", color1: "#1A8A3C", color2: "#0C5C26", sortOrder: 0))
        context.insert(LoyaltyCard(userId: DevAccount.userId, profileId: p1.id,
                                   brand: "Qantas FF", subBrand: nil,
                                   number: "QF1234567", barcodeFormat: "qr",
                                   pointsLabel: nil, color1: "#E40000", color2: "#A30000", sortOrder: 1))

        // quotes: a DRAFT + a SENT (with number + sentAt) + client + line item
        let client = Client(userId: DevAccount.userId, profileId: p1.id,
                            name: "Acme Pty Ltd", email: "accounts@acme.example")
        context.insert(client)
        // DISTINCT createdAt per quote so the "newest first" list is deterministic
        // run-to-run. Both quotes default createdAt to the PINNED Epoch.nowMs(), which
        // would tie the sort key; SwiftData then returns the tied rows in undefined order
        // and the row order flips between tour runs (the pixel-stability gate, Task 7).
        // A \.id tiebreaker can't fix this — ID.uuidv7() reads the real wall clock + random
        // bytes (IDClock.swift), so ids differ every launch. Offset the older (draft) quote
        // one minute behind the sent one; sent stays newest.
        let draft = Quote(userId: DevAccount.userId, profileId: p1.id,
                          clientName: "Northbridge Cafe", clientEmail: "owner@northbridge.example",
                          gstEnabled: true, subtotalCents: 200_00, gstCents: 20_00, totalCents: 220_00,
                          status: "draft", createdAt: Epoch.nowMs() - 60_000)
        context.insert(draft)
        context.insert(QuoteLineItem(userId: DevAccount.userId, quoteId: draft.id,
                                     itemDescription: "Brand identity package", quantity: 1,
                                     unitPriceCents: 200_00, sortOrder: 0))
        let sent = Quote(userId: DevAccount.userId, profileId: p1.id, number: "SN-0001",
                         clientName: "Acme Pty Ltd", clientEmail: "accounts@acme.example",
                         gstEnabled: true, subtotalCents: 800_00, gstCents: 80_00, totalCents: 880_00,
                         status: "sent", sentAt: Epoch.nowMs())
        context.insert(sent)

        // smart rule on p1
        context.insert(SmartRule(userId: DevAccount.userId, profileId: p1.id,
                                 matchType: "merchant_contains", matcher: "BP",
                                 setDeductiblePct: 100, setMode: "business", priority: 0, enabled: true))

        // email-in: one failed (needs review) + one done
        context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, merchant: "",
                                   catKey: "office", amountCents: 0, txnDate: dayISO(4),
                                   isAi: true, source: "email_in", extractionStatus: "failed"))
        context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, merchant: "Officeworks",
                                   catKey: "office", amountCents: -45_00, txnDate: dayISO(2),
                                   isAi: true, gstCents: 4_09, source: "email_in", extractionStatus: "done"))

        // --- p2 (personal) — its OWN data so accent re-skin + profile-switch shoot ---
        context.insert(Transaction(userId: DevAccount.userId, profileId: p2.id, catKey: "income",
                                   amountCents: 320_00, txnDate: dayISO(1)))
        context.insert(Transaction(userId: DevAccount.userId, profileId: p2.id, merchant: "Coles",
                                   catKey: "groceries", amountCents: -64_50, txnDate: dayISO(2)))
        context.insert(Transaction(userId: DevAccount.userId, profileId: p2.id, merchant: "Netflix",
                                   catKey: "software", amountCents: -18_99, txnDate: dayISO(-12)))
        context.insert(Budget(userId: DevAccount.userId, profileId: p2.id, categoryId: nil,
                              label: "Monthly spend", capCents: 200_00, alertThresholdPct: 90))
        context.insert(LoyaltyCard(userId: DevAccount.userId, profileId: p2.id,
                                   brand: "Flybuys", subBrand: nil,
                                   number: "6008941234567", barcodeFormat: "ean13",
                                   pointsLabel: "880 pts", color1: "#0046AD", color2: "#00307A", sortOrder: 0))

        try? context.save()
    }

    /// EMPTY-state tour fixture: signed-in dev session + the SAME two profiles
    /// (so both accents are reachable) but NO domain data — every screen renders
    /// its empty-state art. Pins the clock too (so any "today" header is fixed).
    /// Selected by `-uiTestTourEmpty` (mutually exclusive with `-uiTestTour`).
    /// Spec §4 requires "empty AND populated variants"; §5's designer's-eye lens
    /// explicitly audits empty states.
    func applyTourEmptySeedIfNeeded(authStore: AuthStore, context: ModelContext) {
        guard tourEmpty else { return }
        Epoch.override = 1_768_478_400_000   // same pin as the populated tour
        authStore.save(SessionResponse(
            accessToken: "tour-access", refreshToken: "tour-refresh", expiresIn: 900,
            user: SessionUser(id: DevAccount.userId, email: DevAccount.email, displayName: "Dev")))
        context.insert(Profile(userId: DevAccount.userId, name: "Studio North", type: "business",
                               initials: "SN", accent1: "#0E7C72", accent2: "#DCF0ED", accent3: "#0A5950",
                               sortOrder: 0, isDefault: true))
        context.insert(Profile(userId: DevAccount.userId, name: "Home Budget", type: "personal",
                               initials: "HB", accent1: "#E8602C", accent2: "#FDEBE0", accent3: "#C2461A",
                               sortOrder: 1, isDefault: false))
        try? context.save()
    }

    func makeAPIClient(auth: AuthStore) -> APIClient {
        if useStub { return StubAPIClient() }
        let base = apiBaseURLOverride ?? URL(string: "https://api.snapceipt.cc")!
        return LiveAPIClient(baseURL: base, auth: auth)
    }

    /// The biometric app-lock controller for the run. Under `-uiTestStub` the
    /// evaluator is hard-stubbed (`canEvaluate: { false }`) so the lock never
    /// gates a seeded UI-test launch; otherwise the real `LAContext`-backed
    /// controller is returned. `@MainActor` because `AppLockController` is.
    @MainActor
    func makeAppLock() -> AppLockController {
        if useStub { return AppLockController(canEvaluate: { false }, evaluate: { true }) }
        return AppLockController()
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
