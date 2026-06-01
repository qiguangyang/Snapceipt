import SwiftUI
import SwiftData

/// Tax & GST editor (F7). Placeholder body — fleshed out in Task 8 against
/// `TaxSettingsViewModel`. Compiles with the init params RootView passes.
struct TaxSettingsView: View {
    let profiles: ProfilesStore
    let sync: any SyncEnqueuing
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Tax & GST", onClose: onClose)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.cream)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.taxScreen)
    }
}
