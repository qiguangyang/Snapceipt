import SwiftUI
import SwiftData

/// Smart-rule editor (F7). Placeholder body — fleshed out in Task 9 against
/// `SmartRulesViewModel`. Compiles with the init params RootView passes.
struct RuleEditorView: View {
    let context: ModelContext
    let sync: any SyncEnqueuing
    let userId: String
    let profileId: String
    let ruleId: String?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Smart rule", onClose: onClose)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.cream)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.ruleEditorScreen)
    }
}
