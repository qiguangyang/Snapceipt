import SwiftUI
import SwiftData

@main
struct SnapceiptApp: App {
    /// The app-wide SwiftData container. Built once at launch; later tasks
    /// add models to `SnapceiptSchema` and wire stores (Sync, Profiles, etc.).
    let container: ModelContainer = makeSnapceiptContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}
