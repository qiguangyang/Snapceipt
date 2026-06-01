import SwiftUI
import SwiftData

/// Profile detail / edit / delete screen (F7). Placeholder body — fleshed out in
/// Task 10 against `ProfilesStore`. Compiles with the init params RootView passes.
struct ProfileDetailView: View {
    let profiles: ProfilesStore
    let sync: any SyncEnqueuing
    let profileId: String
    let onClose: () -> Void
    let onExport: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Profile", onClose: onClose)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.cream)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.profileDetailScreen)
    }
}
