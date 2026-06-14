import SwiftUI
import UIKit

/// A right-aligned "hide keyboard" button pinned to the keyboard accessory bar.
///
/// Dismisses whatever field is first responder via the responder chain
/// (`resignFirstResponder`), so a single application works for every keyboard
/// type — including `.numberPad`/`.decimalPad`, which have no return key — and
/// regardless of which field is focused. No per-field `@FocusState` wiring needed.
///
/// Apply `.keyboardDismissButton()` once per presented view hierarchy (a screen
/// or each sheet's body root). Applying it more than once in the same hierarchy
/// would stack duplicate buttons in the accessory bar.
private struct KeyboardDismissButton: ViewModifier {
    @Environment(\.accent) private var accent

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(action: dismissKeyboard) {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(accent.base)
                }
                .accessibilityLabel("Hide keyboard")
                .accessibilityIdentifier(AccessibilityID.keyboardDismiss)
            }
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

extension View {
    /// Adds a "hide keyboard" button to the keyboard accessory bar (right side).
    /// See ``KeyboardDismissButton``. Apply once per screen/sheet body root.
    func keyboardDismissButton() -> some View {
        modifier(KeyboardDismissButton())
    }
}
