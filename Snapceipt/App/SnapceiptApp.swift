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
        let container = makeSnapceiptContainer()
        self.container = container
        // Share the container's main context across the sync/profiles stores and the
        // views' `@Query`/`@Environment(\.modelContext)` so writes are mutually visible.
        let context = container.mainContext

        let auth = AuthStore()
        // Networking base URL. The canonical config/baseURL is owned by the sync task;
        // this is the production host the /auth + /sync contract is served from.
        let baseURL = URL(string: "https://api.snapceipt.app")!
        let api: APIClient = LiveAPIClient(baseURL: baseURL, auth: auth)

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
