import SwiftUI
import SwiftData

@main
struct SnapceiptApp: App {
    /// The app-wide SwiftData container, built once at launch.
    private let container: ModelContainer

    /// Auth + networking. `AuthStore` owns the Keychain-backed session and deviceId;
    /// `LiveAPIClient` is the production network boundary; `AuthViewModel` drives the
    /// sign-in / magic-link / onboarding state machine consumed by `RootView`.
    @State private var auth: AuthStore
    @State private var authVM: AuthViewModel

    /// Shell-wide singletons injected into the environment: navigation (`Router`),
    /// cross-cutting toasts (`ToastCenter`), the offline/sync stack (`Reachability`,
    /// `SyncEngine`), and active-profile state (`ProfilesStore`). The onboarding
    /// first-profile enqueue (Task 12) reaches `SyncEngine` through the environment.
    @State private var router: Router
    @State private var toasts: ToastCenter
    @State private var reachability: Reachability
    @State private var sync: SyncEngine
    @State private var profiles: ProfilesStore
    @State private var clientReminders: ClientReminderRouteCoordinator
    @State private var followUpScheduler: FollowUpNotificationScheduler

    /// Biometric app-lock controller (spec §6). Owned here so the lock state is a
    /// single shared instance across the Privacy toggle (writes `isEnabled`) and the
    /// `RootView` lock gate (reads `isLocked`). Under `-uiTestStub` it is stub-bypassed
    /// (`makeAppLock` injects `canEvaluate: { false }`) so seeded UI-test launches
    /// never block; in Release it uses the real `LAContext`-backed evaluator.
    @State private var appLock: AppLockController
    /// MetricKit crash/hang reporter — registered with MXMetricManager at launch so
    /// diagnostics from the previous run POST to /crash-reports. Held to keep the
    /// subscriber alive. Wired only on the live network boundary (Release), not the
    /// UI-test stub.
    @State private var crashReporter: CrashReporter?

    /// StoreKit 2 service: loads products, drives purchase/restore, listens for
    /// transaction updates. Injected into the environment so PaywallView can call it.
    @State private var storekit: StoreKitService
    /// Union of local StoreKit entitlement and backend plan. The UI reads this to
    /// gate Pro features; injected into the environment.
    @State private var entitlement: EntitlementStore
    /// Retained here (not just in init's local scope) so the storekit/entitlement
    /// callbacks can capture it with a strong reference.
    private let api: APIClient

    /// UIKit app delegate bridging APNs token registration + notification taps. The
    /// Router/APIClient refs it routes through are injected from `init()` below.
    @UIApplicationDelegateAdaptor(NotificationDelegate.self) private var notificationDelegate

    init() {
#if DEBUG
        // UI-test hermeticity: clear cross-run-persisted Cloud AI (Smart Scan) state so each
        // -uiTestStub launch seeds a deterministic default. The simulator reports FM AVAILABLE
        // (forced off under stub in OnDeviceAI.makeExtractor), so a prior run could have persisted
        // Smart Scan OFF (on-device) AND set the one-time non-FM→cloud migration flag — leaving
        // capture on the empty manual path instead of the deterministic cloud stub.
        if AppLaunch.current.useStub {
            UserDefaults.standard.removeObject(forKey: AppSettings.smartScanEnabledKey)
            UserDefaults.standard.removeObject(forKey: "sc.smartScan.nonFMCloudMigration.v1")
        }
#endif
        // Seed the Cloud AI default by device capability (FM available → on-device, else cloud)
        // before any view reads the @AppStorage toggle. No-op once set; never overrides a choice.
        AppSettings.seedSmartScanDefaultIfUnset()
        // One-time: lift EXISTING non-FM devices off the old OFF (manual) default onto Cloud.
        AppSettings.migrateNonFMOffToCloudIfNeeded()
        let auth = AuthStore()
#if DEBUG
        // UI-test seam: under -uiTestStub/-uiTestReset/API_BASE_URL the app wires itself
        // to a hermetic stub + in-memory store. Reset runs BEFORE api/container/userId so
        // the session is cleared before AuthViewModel/userId read it. Compiled out of Release.
        let launch = AppLaunch.current
        launch.applyResetIfNeeded(authStore: auth)
        let api: APIClient = launch.makeAPIClient(auth: auth)
        let container = launch.makeContainer()
        // Purge any cross-run-stale local rows so -uiTestReset starts the store empty
        // (live journeys sign into a fresh account; a leftover profile would skip onboarding).
        launch.purgeLocalStoreIfNeeded(context: container.mainContext)
        launch.applySeedIfNeeded(authStore: auth, context: container.mainContext)
        launch.applyBasSeedIfNeeded(authStore: auth, context: container.mainContext)
        launch.applyTourSeedIfNeeded(authStore: auth, context: container.mainContext)
        launch.applyTourEmptySeedIfNeeded(authStore: auth, context: container.mainContext)
        // Stub-bypassed under -uiTestStub (canEvaluate:{false}) so the lock gate
        // never blocks a seeded UI-test launch.
        let appLock = launch.makeAppLock()
#else
        let api: APIClient = LiveAPIClient(baseURL: BackendConfig.configuredBaseURL, auth: auth)
        let container = makeSnapceiptContainer()
        let appLock = AppLockController()
#endif
        self.container = container
        // Share the container's main context across the sync/profiles stores and the
        // views' `@Query`/`@Environment(\.modelContext)` so writes are mutually visible.
        let context = container.mainContext

        let toasts = ToastCenter()
        let sync = SyncEngine(api: api, context: context, auth: auth, toast: toasts)
        // Scope profiles to the restored session's user (empty when signed out; the
        // shell reloads on appear once a session exists).
        let userId = auth.session?.userId ?? ""
        let profiles = ProfilesStore(context: context, sync: sync, userId: userId)

        let router = Router()
#if DEBUG
        // UI-screenshot seam: `-uiTestTab <home|activity|reports|profile>` lands the
        // shell on a specific tab so each screen can be captured without tapping.
        if let i = CommandLine.arguments.firstIndex(of: "-uiTestTab"),
           i + 1 < CommandLine.arguments.count,
           let t = Tab(rawValue: CommandLine.arguments[i + 1]) {
            router.tab = t
        }
#endif

        // Subscription stack: wire StoreKit → EntitlementStore callbacks before
        // storing, so any launch-time transaction update is handled immediately.
        let entitlement = EntitlementStore()
        let storekit = StoreKitService()
        storekit.onEntitlementChange = { entitled in entitlement.setLocalEntitled(entitled) }
        storekit.onVerifiedTransaction = { signedTransaction in
            // POST the signed StoreKit transaction JWS to the backend, which verifies Apple's
            // signature/cert chain and derives the entitlement from the verified payload. Retries
            // transient failures; on a persistent failure we surface it (the local entitlement
            // already unlocked the UI, but the server — which gates Pro features like email-in —
            // would otherwise silently stay free, as it did before this).
            Task {
                if !(await recordPurchaseWithRetry(api: api, jws: signedTransaction)) {
                    toasts.show("Couldn't confirm your purchase with the server — we'll retry automatically.",
                                kind: .error)
                }
            }
        }
        self.api = api
        _storekit = State(initialValue: storekit)
        _entitlement = State(initialValue: entitlement)

        let followUpScheduler = FollowUpNotificationScheduler(context: context)
        followUpScheduler.setUser(auth.session?.userId)
        _followUpScheduler = State(initialValue: followUpScheduler)
        let clientReminders = ClientReminderRouteCoordinator(context: context, profiles: profiles,
            router: router, currentUser: { auth.session?.userId })
        _clientReminders = State(initialValue: clientReminders)

        _auth = State(initialValue: auth)
        _authVM = State(initialValue: AuthViewModel(
            api: api, auth: auth,
            // Wipe local financial data + receipt images on sign-out / account deletion.
            onWipeLocalData: {
                clientReminders.invalidateAuthentication()
                router.dismissOverlay()
                followUpScheduler.invalidateAuthentication()
                LocalStore.wipe(context: context)
            }))
        _router = State(initialValue: router)
        _toasts = State(initialValue: toasts)
        _reachability = State(initialValue: Reachability())
        _sync = State(initialValue: sync)
        _profiles = State(initialValue: profiles)
        _appLock = State(initialValue: appLock)
#if DEBUG
        _crashReporter = State(initialValue: nil)
#else
        _crashReporter = State(initialValue: CrashReporter(api: api))
#endif

        // Inject the SAME Router + APIClient instances into the APNs delegate (UIKit
        // owns the adaptor, so we hand it shared refs). Taps route to the live shell.
        NotificationDelegate.clientReminderCoordinator = clientReminders
        NotificationDelegate.router = router
        NotificationDelegate.api = api
        // Email-in push refresh seam: a tapped/foreground email-in push triggers a sync,
        // then posts .emailInReceiptArrived so an open EmailInView re-fetches its inbox
        // (the list is a manual fetch, not a @Query, so it won't auto-refresh on the sync write).
        NotificationDelegate.refreshOnPush = {
            await sync.sync()
            await MainActor.run { NotificationCenter.default.post(name: .emailInReceiptArrived, object: nil) }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(authVM)
                .environment(auth)
                .environment(router)
                .environment(toasts)
                .environment(reachability)
                .environment(sync)
                .environment(profiles)
                .environment(clientReminders)
                .environment(followUpScheduler)
                .environment(appLock)
                .environment(storekit)
                .environment(entitlement)
                .modelContainer(container)
                .onOpenURL { url in
                    // Share Extension (snapceipt://import): just bring the app forward — the inbox
                    // drain on launch/foreground reads the shared receipt. Don't route it through
                    // the budget/auth deep-link handlers.
                    if url.scheme == "snapceipt", url.host == "import" { return }
                    // Budget deep-link (snapceipt://budget/<id>) routes to the editor first.
                    if router.handleBudgetDeepLink(url) { return }
                    // Magic-link Universal Link / custom-scheme deep link.
                    Task { await authVM.handleDeepLink(url) }
                }
                .task {
                    // Sync entitlements at launch: local StoreKit + backend plan.
                    await storekit.refreshEntitlements()
                    if let plan = try? await api.mePlan() {
                        entitlement.applyServerPlan(plan)
                        // Reconcile a local-only entitlement: StoreKit says Pro but the server
                        // doesn't (a purchase whose recordPurchase failed, or one predating this
                        // install). Re-send the entitling JWS so the backend — which gates Pro
                        // features like email-in — catches up.
                        if entitlement.localEntitled, plan != "pro",
                           let jws = storekit.currentEntitlementJWS,
                           await recordPurchaseWithRetry(api: api, jws: jws) {
                            entitlement.applyServerPlan("pro")
                        }
                    }
                    // Default Cloud AI by plan now that the entitlement is known: ON for Pro, OFF for
                    // Free (no-op once the user has pinned the toggle, or auto-disabled it at the cap).
                    AppSettings.applyPlanDefaultSmartScan(isPro: entitlement.isPro)
                }
                .onChange(of: entitlement.isPro) { _, isPro in
                    // Upgrade flips an unpinned toggle ON; a downgrade flips it OFF.
                    AppSettings.applyPlanDefaultSmartScan(isPro: isPro)
                }
        }
    }
}
