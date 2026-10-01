import Foundation
import SwiftData
import UIKit

#if DEBUG
/// Parses UI-test launch arguments/environment to decide how the app wires itself.
/// Every surface here is compiled out of Release builds.
struct AppLaunch {
    let useStub: Bool
    let reset: Bool
    let clientWorkspace: Bool
    let seed: Bool
    let basSeed: Bool
    let lockAvailable: Bool
    let tour: Bool
    let tourEmpty: Bool
    /// `-uiTestActiveType personal|business`: which seeded profile is active on launch
    /// (quick actions are profile-type-gated, so type-specific tests pick the right one).
    let activeType: String?
    /// `-uiTestPro`: the stub reports a "pro" plan so Pro-gated features (Quotes, Email-in,
    /// Mileage, WFH) are reachable without the paywall (StoreKit purchase can't complete
    /// in the UI-test stub, so a test can't subscribe through the paywall).
    let pro: Bool
    let cannedNeedsReview: Bool
    /// Test seam (`-uiTestOffline`): the API client throws a transport error on
    /// `extract`/`uploadImage`, forcing the capture flow's queued-for-the-cloud
    /// fallback (empty draft + outbox queue) exactly as a real offline capture
    /// would — on-device AI if available, else queued for the cloud reconciler.
    /// Drives J18b/J18c.
    let offline: Bool
    /// Test seam (`-uiTestPushReject`): the stub `syncPush` throws a 422 contract
    /// rejection so `SyncEngine` marks the batch failed and surfaces `.error`.
    /// Drives J23b (visible-failure).
    let pushReject: Bool
    /// Test seam (`-uiTestPushStall`): both the stub and live `syncPush` sleep
    /// indefinitely instead of returning. `SyncEngine.push()` marks the batch
    /// `inflight` + saves BEFORE calling `syncPush` (SyncEngine.swift:104-105), so
    /// `app.terminate()` while the call is parked strands a persisted `inflight`
    /// outbox row — the exact crash-recovery precondition for J23c. On the on-disk
    /// live store (no `-uiTestStub`) that row survives the relaunch, where
    /// `requeueStrandedInflight()` (run unconditionally at the head of every push)
    /// re-marks it `pending` and the next clean push drains it. DEBUG-only.
    let pushStall: Bool
    /// Test seam (`-uiTestCaptureCamera`): keep the capture flow on `.camera` (suppress
    /// the canned-image feed) AND render a neutral placeholder instead of the live
    /// `VNDocumentCameraViewController` (unsupported in the simulator) — so the import
    /// affordance on the camera stage is hermetically inspectable. DEBUG-only.
    let captureCamera: Bool
    /// Test seam (`-uiTestSkipPermissions`): wire the NO-OP permission requester in
    /// onboarding even on the non-stub (live) path, so a UI test never triggers a real
    /// system camera/notifications alert it can't dismiss (the priming screen now always
    /// advances into the OS prompt — there is no "Not now" skip). Set for every UI test by
    /// `UITestCase.setUp`. DEBUG-only; the shipped app always uses the live requester.
    let skipPermissions: Bool
    let apiBaseURLOverride: URL?

    init(arguments: [String] = ProcessInfo.processInfo.arguments,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        useStub = arguments.contains("-uiTestStub")
        reset = arguments.contains("-uiTestReset")
        clientWorkspace = arguments.contains("-uiTestClientWorkspace")
        seed = arguments.contains("-uiTestSeed")
        basSeed = arguments.contains("-uiTestBasSeed")
        lockAvailable = arguments.contains("-uiTestLockAvailable")
        tour = arguments.contains("-uiTestTour")
        tourEmpty = arguments.contains("-uiTestTourEmpty")
        activeType = arguments.firstIndex(of: "-uiTestActiveType").flatMap {
            $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
        }
        pro = arguments.contains("-uiTestPro")
        cannedNeedsReview = arguments.contains("-uiTestCannedNeedsReview")
        offline = arguments.contains("-uiTestOffline")
        pushReject = arguments.contains("-uiTestPushReject")
        pushStall = arguments.contains("-uiTestPushStall")
        captureCamera = arguments.contains("-uiTestCaptureCamera")
        skipPermissions = arguments.contains("-uiTestSkipPermissions")
        apiBaseURLOverride = environment["API_BASE_URL"].flatMap(URL.init(string:))
    }

    static let current = AppLaunch()

    /// Clears dev-namespaced auth + active-profile + sync-cursor state so a UI test starts signed-out + empty.
    func applyResetIfNeeded(authStore: AuthStore) {
        guard reset else { return }
        authStore.clear()
        UserDefaults.standard.removeObject(forKey: "sc.activeProfile")
        UserDefaults.standard.removeObject(forKey: "sc.syncCursor")
        // Clear the app-lock flag too: J08 (AppLockUITests) persists sc.lock.enabled=true
        // and it survives across launches in the simulator container. Without this, a
        // later -uiTestReset launch — including the live (E2E_LIVE) suite, which runs
        // WITHOUT -uiTestStub and so gets the real LAContext evaluator that can't succeed
        // on a passcode-less simulator — would lock the shell permanently. -uiTestReset
        // heals it for both the hermetic and live paths.
        UserDefaults.standard.removeObject(forKey: "sc.lock.enabled")
        // Clear the first-run completion flag so a -uiTestReset launch starts at onboarding.
        OnboardingGate.reset()
    }

    /// Purges the on-disk SwiftData store under `-uiTestReset` so a live journey that
    /// signs into a FRESH backend account isn't blocked by a stale Profile left in the
    /// local container by a PRIOR run. RootView's onboarding gate is a GLOBAL
    /// `@Query profileRows.isEmpty` (all users), so a leftover profile from any earlier
    /// run suppresses onboarding for the new account — leaving the new user with no
    /// active profile and dead-ending capture's save() (J18c). The hermetic path uses an
    /// in-memory store (purge is a harmless no-op there; seeds run afterwards and never
    /// pass `-uiTestReset`). DEBUG-only seam; never compiled into Release.
    func purgeLocalStoreIfNeeded(context: ModelContext) {
        guard reset else { return }
        // Fail FAST on a delete/save error: this purge is the fix for the stale-Profile
        // bug J18c root-caused, so a silently-swallowed failure would resurface as an
        // unexplained downstream test failure (onboarding skipped → no active profile →
        // capture.save() dead-ends). assertionFailure fires only in DEBUG (this whole
        // struct is #if DEBUG), so it's a loud test-time signal, never a Release crash.
        // NOTE: deleting PendingReceipt rows orphans their JPEGs under Application Support
        // (ReceiptCleanupPass reclaims by row, not by orphan sweep), so live-run simulators
        // slowly accumulate orphan files. Harmless for the simulator container.
        do {
            for type in SnapceiptSchema.models {
                try context.delete(model: type)
            }
            try context.save()
        } catch {
            assertionFailure("purgeLocalStoreIfNeeded failed: \(error)")
        }
    }

    /// Seeds an already-signed-in dev session + two profiles, for shell-level UI tests
    /// where the profile switcher must be enabled (needs >1 profile). DEBUG only.
    func applySeedIfNeeded(authStore: AuthStore, context: ModelContext) {
        guard seed else { return }
        // A seeded user is already onboarded — skip first-run priming so the launch
        // lands directly in the shell (the cleared onboarding flag would otherwise
        // show OnboardingView instead of the seeded tabs).
        OnboardingGate.markComplete()
        authStore.save(SessionResponse(
            accessToken: "seed-access", refreshToken: "seed-refresh", expiresIn: 900,
            user: SessionUser(id: DevAccount.userId, email: DevAccount.email, displayName: "Dev")))
        let p1 = Profile(id: useStub && clientWorkspace ? "01990000-0000-7000-8000-000000000101" : ID.uuidv7(), userId: DevAccount.userId, name: "Studio North", type: "business",
                         initials: "SN", accent1: "#0E7C72", accent2: "#DCF0ED", accent3: "#0A5950",
                         sortOrder: 0, isDefault: true)
        let p2 = Profile(userId: DevAccount.userId, name: "Home Budget", type: "personal",
                         initials: "HB", accent1: "#E8602C", accent2: "#FDEBE0", accent3: "#C2461A",
                         sortOrder: 1, isDefault: false)
        context.insert(p1); context.insert(p2)
        // Quick actions are profile-type-gated, so let a test choose which seeded profile
        // is active on launch (default = the business p1, matching isDefault). The key is
        // ProfilesStore's persisted "sc.activeProfile", read in its init below.
        UserDefaults.standard.set(activeType == "personal" ? p2.id : p1.id, forKey: "sc.activeProfile")
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
        context.insert(LoyaltyCard(userId: DevAccount.userId, profileId: p1.id,
                                   brand: "Flybuys", subBrand: nil, number: "6011000990139424",
                                   barcodeFormat: "code128", pointsLabel: nil,
                                   color1: "#005EB8", color2: "#003E7E", sortOrder: 2))
        context.insert(LoyaltyCard(userId: DevAccount.userId, profileId: p1.id,
                                   brand: "Boarding Pass", subBrand: nil, number: "PDF417DATA12345",
                                   barcodeFormat: "pdf417", pointsLabel: nil,
                                   color1: "#444444", color2: "#222222", sortOrder: 3))
        // Mirror the loyalty cards (all 4 barcode formats) + a vehicle logbook onto the
        // PERSONAL profile p2: with strict profile-type gating, Loyalty/Mileage/WFH quick
        // actions only appear on a personal Home, so those tests run under
        // `-uiTestActiveType personal` and need their data on p2.
        for (i, fmt) in [("Everyday Rewards", "5901234123457", "ean13", "1,240 pts", "#1A8A3C", "#0C5C26"),
                         ("Qantas FF", "QF1234567", "qr", "", "#E40000", "#A30000"),
                         ("Flybuys", "6011000990139424", "code128", "", "#005EB8", "#003E7E"),
                         ("Boarding Pass", "PDF417DATA12345", "pdf417", "", "#444444", "#222222")].enumerated() {
            context.insert(LoyaltyCard(userId: DevAccount.userId, profileId: p2.id,
                                       brand: fmt.0, subBrand: nil, number: fmt.1,
                                       barcodeFormat: fmt.2, pointsLabel: fmt.3.isEmpty ? nil : fmt.3,
                                       color1: fmt.4, color2: fmt.5, sortOrder: i))
        }
        context.insert(VehicleYear(userId: DevAccount.userId, profileId: p2.id, vehicleId: "v2",
                                   fyStartYear: FinancialYear.of(Date(), startMonth: 7).startYear, claimCents: 0))
        // F5: seed a saved client + a draft quote (+ one line item) on p1 (active business).
        let client = Client(id: useStub && clientWorkspace ? "01990000-0000-7000-8000-000000000103" : ID.uuidv7(), userId: DevAccount.userId, profileId: p1.id,
                            name: "Acme Pty Ltd", email: "accounts@acme.example")
        context.insert(client)
        // Optional extension of the existing hermetic fixture, reached through Business Home.
        // Clock values intentionally include DST correction cases; production has no route seam.
        if useStub && clientWorkspace {
            client.notes = String(repeating: "Discuss access, materials and timing before preparing the next draft. ", count: 30)
            client.mobilePhone = "0400 123 456"
            let formatter = ISO8601DateFormatter()
            for (index, pair) in [("DST gap inspection", "2026-10-04T02:30:00Z"), ("DST overlap inspection", "2027-04-04T02:30:00Z")].enumerated() {
                let (title, instant) = pair
                context.insert(ClientFollowUp(id: String(format: "01990000-0000-7000-8000-%012d", 120 + index), userId: DevAccount.userId, profileId: p1.id, clientId: client.id,
                    title: title, dueAt: Int(formatter.date(from: instant)!.timeIntervalSince1970 * 1000), timezone: "UTC"))
            }
        }
        let quote = Quote(id: useStub && clientWorkspace ? "01990000-0000-7000-8000-000000000104" : ID.uuidv7(), userId: DevAccount.userId, profileId: p1.id,
                          clientName: "Northbridge Cafe", clientEmail: "owner@northbridge.example",
                          gstEnabled: true, subtotalCents: 200_00, gstCents: 20_00, totalCents: 220_00,
                          status: "draft")
        context.insert(quote)
        if useStub && clientWorkspace { quote.clientId = client.id }
        context.insert(QuoteLineItem(id: useStub && clientWorkspace ? "01990000-0000-7000-8000-000000000105" : ID.uuidv7(), userId: DevAccount.userId, quoteId: quote.id,
                                     itemDescription: clientWorkspace ? String(repeating: "Brand identity package with full design descriptions. ", count: 12) : "Brand identity package", quantity: 1,
                                     unitPriceCents: 200_00, sortOrder: 0))
        if useStub && clientWorkspace {
            let invoice = Invoice(id: "01990000-0000-7000-8000-000000000106", userId: DevAccount.userId, profileId: p1.id, number: "INV-REPEAT", clientId: client.id,
                clientName: client.name, gstEnabled: true, subtotalCents: 10000, gstCents: 1000, totalCents: 11000,
                status: "issued", issueDate: "2020-08-01", dueDate: "2020-09-01", issuedAt: 1596240000000)
            context.insert(invoice)
            context.insert(InvoiceLineItem(id: "01990000-0000-7000-8000-000000000107", userId: DevAccount.userId, invoiceId: invoice.id,
                itemDescription: String(repeating: "Detailed prior work description for review. ", count: 12), unitPriceCents: 10000))
            context.insert(Payment(id: "01990000-0000-7000-8000-000000000108", userId: DevAccount.userId, invoiceId: invoice.id, amountCents: 11000, paidOn: "2020-08-02"))
            context.insert(CatalogItem(id: "01990000-0000-7000-8000-000000000109", userId: DevAccount.userId, profileId: p1.id, itemDescription: "Journey consulting", unitLabel: "hour", unitPriceCents: 12500))
            context.insert(CatalogItem(id: "01990000-0000-7000-8000-000000000118", userId: DevAccount.userId, profileId: p1.id, itemDescription: "NZD consulting", unitLabel: "hour", unitPriceCents: 12500, currency: "NZD"))
            let legacy = Quote(id: "01990000-0000-7000-8000-000000000110", userId: DevAccount.userId, profileId: p1.id, number: "Q-LEGACY", clientName: "Legacy snapshot contact", clientEmail: "legacy@example.test", clientAddress: "Original site address", clientMobile: "0400111222", subtotalCents: 1000, gstCents: 100, totalCents: 1100)
            context.insert(legacy)
            context.insert(QuoteLineItem(id: "01990000-0000-7000-8000-000000000111", userId: DevAccount.userId, quoteId: legacy.id, itemDescription: "Historical work", unitPriceCents: 1000))
            let south = Profile(id: "01990000-0000-7000-8000-000000000112", userId: DevAccount.userId, name: "Journey South", type: "business", initials: "JS", accent1: "#0E7C72", accent2: "#DCF0ED", accent3: "#0A5950", sortOrder: 2)
            context.insert(south)
            let southClient = Client(id: "01990000-0000-7000-8000-000000000113", userId: DevAccount.userId, profileId: south.id, name: "South client", notes: "South confidential notes")
            context.insert(southClient)
            let southInvoice = Invoice(id: "01990000-0000-7000-8000-000000000114", userId: DevAccount.userId, profileId: south.id, number: "INV-SOUTH", clientId: southClient.id, clientName: southClient.name, subtotalCents: 5000, gstCents: 500, totalCents: 5500, status: "issued")
            context.insert(southInvoice)
            context.insert(InvoiceLineItem(id: "01990000-0000-7000-8000-000000000115", userId: DevAccount.userId, invoiceId: southInvoice.id, itemDescription: "South work", unitPriceCents: 5000))
            context.insert(Payment(id: "01990000-0000-7000-8000-000000000116", userId: DevAccount.userId, invoiceId: southInvoice.id, amountCents: 500, paidOn: "2026-09-01"))
            context.insert(CatalogItem(id: "01990000-0000-7000-8000-000000000117", userId: DevAccount.userId, profileId: south.id, itemDescription: "South saved item", unitPriceCents: 5000))
            context.insert(ClientFollowUp(id: "01990000-0000-7000-8000-000000000118", userId: DevAccount.userId, profileId: south.id, clientId: southClient.id, title: "South reminder", dueAt: 1800000000000, timezone: "Australia/Sydney"))

        }
        // F6: two email-in receipts on the business profile — one failed (needs review),
        // one done — so EmailInUITests can exercise the failed-first list + review flow.
        context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, merchant: "",
                                   catKey: "office", amountCents: 0, txnDate: dayISO(4),
                                   isAi: true, source: "email_in", extractionStatus: "failed"))
        context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, merchant: "Officeworks",
                                   catKey: "office", amountCents: -45_00, txnDate: dayISO(2),
                                   isAi: true, gstCents: 4_09, source: "email_in", extractionStatus: "done"))
        // p2 (personal) distinct data so profile-scope leaks are observable in both directions.
        context.insert(Transaction(userId: DevAccount.userId, profileId: p2.id, merchant: "Coles Personal",
                                   catKey: "groceries", amountCents: -64_00, txnDate: dayISO(2)))
        context.insert(Budget(userId: DevAccount.userId, profileId: p2.id, categoryId: nil,
                              label: "Personal cap", capCents: 300_00, alertThresholdPct: 90))
        try? context.save()
    }

    /// BAS fixture: a GST-registered Business profile p1 with the canonical scenario
    /// (income left unconfirmed → headline "Estimated") + a NON-registered business p2
    /// to verify the card is hidden. Under -uiTestBasSeed.
    func applyBasSeedIfNeeded(authStore: AuthStore, context: ModelContext) {
        guard basSeed else { return }
        OnboardingGate.markComplete()   // seeded user is already onboarded → shell
        authStore.save(SessionResponse(
            accessToken: "basseed-access", refreshToken: "basseed-refresh", expiresIn: 900,
            user: SessionUser(id: DevAccount.userId, email: DevAccount.email, displayName: "Dev")))
        let p1 = Profile(userId: DevAccount.userId, name: "Studio North", type: "business",
                         initials: "SN", accent1: "#0E7C72", accent2: "#DCF0ED", accent3: "#0A5950",
                         gstRegistered: true, sortOrder: 0, isDefault: true)
        let p2 = Profile(userId: DevAccount.userId, name: "Side Hustle", type: "business",
                         initials: "SH", accent1: "#E8602C", accent2: "#FDEBE0", accent3: "#C2461A",
                         gstRegistered: false, sortOrder: 1, isDefault: false)
        context.insert(p1); context.insert(p2)
        let cal: Calendar = {
            var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
        }()
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        let iso: DateFormatter = {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"; return f
        }()
        func day(_ d: Int) -> String { iso.string(from: cal.date(byAdding: .day, value: d, to: monthStart)!) }
        // Income (unconfirmed → headline reads "Estimated" until reviewed).
        context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, catKey: "income",
                                   amountCents: 1_100_000, txnDate: day(1), gstSource: "derived"))
        context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, merchant: "Officeworks",
                                   catKey: "office", amountCents: -110_000, txnDate: day(2), gstSource: "derived"))
        context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, merchant: "Apple",
                                   catKey: "software", amountCents: -220_000, txnDate: day(3),
                                   capital: true, gstSource: "derived"))
        context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, merchant: "Woolworths",
                                   catKey: "groceries", amountCents: -33_000, txnDate: day(4),
                                   gstFree: true, gstSource: nil))
    }

    /// Tour-only fixture: a superset of the seed fixture, populated on BOTH
    /// profiles, with months spread, a real Vehicle + trips, WFH logs, a smart
    /// rule, and a SENT quote — so `ScreenshotTourUITests` can shoot every
    /// populated state on each accent. Selected by `-uiTestTour` (independent of
    /// `-uiTestSeed`, which 11 existing classes still depend on unchanged).
    func applyTourSeedIfNeeded(authStore: AuthStore, context: ModelContext) {
        guard tour else { return }
        OnboardingGate.markComplete()   // seeded user is already onboarded → shell
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
        // Let a tour-area test start on a specific profile type (quick actions are gated).
        UserDefaults.standard.set(activeType == "personal" ? p2.id : p1.id, forKey: "sc.activeProfile")

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
        // Richer current-month demo data so the Home hero + Reports + Activity read as an
        // active business month in marketing screenshots (a client payment + varied
        // deductible expenses). Deterministic dates (monthStart-relative) keep the tour stable.
        context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, merchant: "Acme Pty Ltd",
                                   catKey: "income", amountCents: 2_400_00, txnDate: dayISO(6),
                                   note: "Invoice SN-0001"))
        context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, merchant: "JB Hi-Fi",
                                   catKey: "office", amountCents: -129_00, txnDate: dayISO(7),
                                   deductiblePct: 100, gstCents: 11_73))
        context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, merchant: "Uber",
                                   catKey: "travel", amountCents: -32_40, txnDate: dayISO(9),
                                   deductiblePct: 100, gstCents: 2_95))
        context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, merchant: "Canva Pro",
                                   catKey: "software", amountCents: -21_99, txnDate: dayISO(10),
                                   deductiblePct: 100, gstCents: 2_00))
        context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, merchant: "Bunnings",
                                   catKey: "office", amountCents: -64_90, txnDate: dayISO(11),
                                   deductiblePct: 100, gstCents: 5_90))

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

        // invoices: an accounts-receivable spread so the Invoices list shows the
        // "Needs attention" (overdue) section + Paid/Unpaid/Partial badges in screenshots.
        // dueDate uses monthStart-relative Jan dates → always past vs the real tour run date,
        // so the issued+unpaid rows read as Overdue deterministically (no shipping-view change).
        let invPaid = Invoice(userId: DevAccount.userId, profileId: p1.id, number: "INV-0006",
                              clientName: "Harbour Studios", clientEmail: "hello@harbour.example",
                              gstEnabled: true, subtotalCents: 2_000_00, gstCents: 200_00, totalCents: 2_200_00,
                              status: "issued", issueDate: dayISO(2), dueDate: dayISO(12),
                              issuedAt: Epoch.nowMs() - 30_000, createdAt: Epoch.nowMs() - 30_000)
        context.insert(invPaid)
        context.insert(InvoiceLineItem(userId: DevAccount.userId, invoiceId: invPaid.id,
                                       itemDescription: "Brand video production", quantity: 1, unitPriceCents: 2_000_00, sortOrder: 0))
        context.insert(Payment(userId: DevAccount.userId, invoiceId: invPaid.id, amountCents: 2_200_00, paidOn: dayISO(9)))
        let invUnpaid = Invoice(userId: DevAccount.userId, profileId: p1.id, number: "INV-0007",
                                clientName: "Lighthouse Co", clientEmail: "ap@lighthouse.example",
                                gstEnabled: true, subtotalCents: 480_00, gstCents: 48_00, totalCents: 528_00,
                                status: "issued", issueDate: dayISO(6), dueDate: nil,
                                issuedAt: Epoch.nowMs() - 60_000, createdAt: Epoch.nowMs() - 60_000)
        context.insert(invUnpaid)
        context.insert(InvoiceLineItem(userId: DevAccount.userId, invoiceId: invUnpaid.id,
                                       itemDescription: "Social media templates", quantity: 1, unitPriceCents: 480_00, sortOrder: 0))
        let invOverdue = Invoice(userId: DevAccount.userId, profileId: p1.id, number: "INV-0008",
                                 clientName: "Acme Pty Ltd", clientEmail: "accounts@acme.example",
                                 gstEnabled: true, subtotalCents: 1_200_00, gstCents: 120_00, totalCents: 1_320_00,
                                 status: "issued", issueDate: dayISO(1), dueDate: dayISO(3),
                                 issuedAt: Epoch.nowMs() - 120_000, createdAt: Epoch.nowMs() - 120_000)
        context.insert(invOverdue)
        context.insert(InvoiceLineItem(userId: DevAccount.userId, invoiceId: invOverdue.id,
                                       itemDescription: "Website design — phase 1", quantity: 1, unitPriceCents: 1_200_00, sortOrder: 0))
        let invPartial = Invoice(userId: DevAccount.userId, profileId: p1.id, number: "INV-0005",
                                 clientName: "Northbridge Cafe", clientEmail: "owner@northbridge.example",
                                 gstEnabled: true, subtotalCents: 600_00, gstCents: 60_00, totalCents: 660_00,
                                 status: "issued", issueDate: dayISO(4), dueDate: dayISO(5),
                                 issuedAt: Epoch.nowMs() - 90_000, createdAt: Epoch.nowMs() - 90_000)
        context.insert(invPartial)
        context.insert(InvoiceLineItem(userId: DevAccount.userId, invoiceId: invPartial.id,
                                       itemDescription: "Menu photography", quantity: 1, unitPriceCents: 600_00, sortOrder: 0))
        context.insert(Payment(userId: DevAccount.userId, invoiceId: invPartial.id, amountCents: 300_00, paidOn: dayISO(2)))

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
        OnboardingGate.markComplete()   // seeded user is already onboarded → shell
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
        if useStub { return StubAPIClient(pro: pro) }
        // Precedence: process-env override (UI tests / quick redirects) > the host baked
        // into this build config (Staging) > prod.
        let base = apiBaseURLOverride ?? BackendConfig.configuredBaseURL
        return LiveAPIClient(baseURL: base, auth: auth)
    }

    /// The biometric app-lock controller for the run. Under `-uiTestStub` the
    /// evaluator reports `canEvaluate: { lockAvailable }` — false by default so the
    /// lock never gates a seeded UI-test launch, but `-uiTestLockAvailable` flips it
    /// true with an always-succeed evaluator so the J08 lock journey can run;
    /// otherwise the real `LAContext`-backed controller is returned. `@MainActor`
    /// because `AppLockController` is.
    @MainActor
    func makeAppLock() -> AppLockController {
        if useStub {
            // Default stub disables biometrics; -uiTestLockAvailable enables a
            // deterministic always-succeed evaluator so the lock journey can run.
            return AppLockController(canEvaluate: { self.lockAvailable },
                                     evaluate: { true })
        }
        return AppLockController()
    }

    func makeContainer() -> ModelContainer {
        makeSnapceiptContainer(inMemory: useStub)
    }

    /// Canned (image, rawText) for the camera-less capture UI test. Loaded from the
    /// app bundle when `-uiTestStub` OR `-uiTestOffline` is set; nil otherwise
    /// (production uses the camera). `-uiTestOffline` is admitted so the LIVE offline
    /// journey (J18c, no `-uiTestStub`) can still drive a camera-less capture against the
    /// real backend; both flags are test-only, so the seam never loads in production.
    var cannedScan: (image: UIImage, rawText: String)? {
        guard useStub || offline,
              let url = Bundle.main.url(forResource: "canned-receipt", withExtension: "jpg"),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return nil }
        let rawText = "THE GROUNDS\n28/05/2026\nFlat White x2  9.00\nBig Brekkie 24.00\nGST 3.86\nTOTAL 42.50"
        return (image, rawText)
    }
}
#endif
