import SwiftUI
import SwiftData

/// Categories & smart-rules screen (F7). Placeholder body — fleshed out in Task 9
/// against `CategoriesViewModel` + `SmartRulesViewModel`. Compiles with the init
/// params RootView passes.
struct CategoriesView: View {
    let context: ModelContext
    let sync: any SyncEnqueuing
    let userId: String
    let profileId: String
    let onEditRule: (String?) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Categories & rules", onClose: onClose)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.cream)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.categoriesScreen)
    }
}
