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
#else
        let api: APIClient = LiveAPIClient(baseURL: URL(string: "https://api.snapceipt.app")!, auth: auth)
        let container = makeSnapceiptContainer()
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

        _auth = State(initialValue: auth)
        _authVM = State(initialValue: AuthViewModel(api: api, auth: auth))
        _router = State(initialValue: Router())
        _toasts = State(initialValue: toasts)
        _reachability = State(initialValue: Reachability())
        _sync = State(initialValue: sync)
        _profiles = State(initialValue: profiles)
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
                .modelContainer(container)
                .onOpenURL { url in
                    // Magic-link Universal Link / custom-scheme deep link.
                    Task { await authVM.handleDeepLink(url) }
                }
        }
    }
}
