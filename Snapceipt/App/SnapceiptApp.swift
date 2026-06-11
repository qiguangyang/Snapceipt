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

    /// Biometric app-lock controller (spec §6). Owned here so the lock state is a
    /// single shared instance across the Privacy toggle (writes `isEnabled`) and the
    /// `RootView` lock gate (reads `isLocked`). Under `-uiTestStub` it is stub-bypassed
    /// (`makeAppLock` injects `canEvaluate: { false }`) so seeded UI-test launches
    /// never block; in Release it uses the real `LAContext`-backed evaluator.
    @State private var appLock: AppLockController

    /// UIKit app delegate bridging APNs token registration + notification taps. The
    /// Router/APIClient refs it routes through are injected from `init()` below.
    @UIApplicationDelegateAdaptor(NotificationDelegate.self) private var notificationDelegate

    init() {
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
        launch.applyTourSeedIfNeeded(authStore: auth, context: container.mainContext)
        launch.applyTourEmptySeedIfNeeded(authStore: auth, context: container.mainContext)
        // Stub-bypassed under -uiTestStub (canEvaluate:{false}) so the lock gate
        // never blocks a seeded UI-test launch.
        let appLock = launch.makeAppLock()
#else
        let api: APIClient = LiveAPIClient(baseURL: URL(string: "https://api.snapceipt.cc")!, auth: auth)
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

        _auth = State(initialValue: auth)
        _authVM = State(initialValue: AuthViewModel(api: api, auth: auth))
        _router = State(initialValue: router)
        _toasts = State(initialValue: toasts)
        _reachability = State(initialValue: Reachability())
        _sync = State(initialValue: sync)
        _profiles = State(initialValue: profiles)
        _appLock = State(initialValue: appLock)

        // Inject the SAME Router + APIClient instances into the APNs delegate (UIKit
        // owns the adaptor, so we hand it shared refs). Taps route to the live shell.
        NotificationDelegate.router = router
        NotificationDelegate.api = api
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
                .environment(appLock)
                .modelContainer(container)
                .onOpenURL { url in
                    // Budget deep-link (snapceipt://budget/<id>) routes to the editor first.
                    if router.handleBudgetDeepLink(url) { return }
                    // Magic-link Universal Link / custom-scheme deep link.
                    Task { await authVM.handleDeepLink(url) }
                }
        }
    }
}
