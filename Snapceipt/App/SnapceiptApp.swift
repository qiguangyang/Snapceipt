import SwiftUI
import SwiftData

@main
struct SnapceiptApp: App {
    /// The app-wide SwiftData container. Built once at launch; later tasks
    /// add models to `SnapceiptSchema` and wire stores (Sync, Profiles, etc.).
    private let container: ModelContainer

    /// Auth + networking. `AuthStore` owns the Keychain-backed session and deviceId;
    /// `LiveAPIClient` is the production network boundary; `AuthViewModel` drives the
    /// sign-in / magic-link / onboarding state machine consumed by `RootView`.
    @State private var auth: AuthStore
    @State private var authVM: AuthViewModel

    init() {
        let container = makeSnapceiptContainer()
        self.container = container

        let auth = AuthStore()
        // Networking base URL. The canonical config/baseURL is owned by the sync task;
        // this is the production host the /auth + /sync contract is served from.
        let baseURL = URL(string: "https://api.snapceipt.app")!
        let api: APIClient = LiveAPIClient(baseURL: baseURL, auth: auth)

        _auth = State(initialValue: auth)
        _authVM = State(initialValue: AuthViewModel(api: api, auth: auth))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(authVM)
                .environment(auth)
                .modelContainer(container)
                .onOpenURL { url in
                    // Magic-link Universal Link / custom-scheme deep link.
                    Task { await authVM.handleDeepLink(url) }
                }
        }
    }
}
