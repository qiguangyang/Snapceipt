import SwiftUI
import UIKit

/// Publishes whether the software keyboard is currently showing. Used to hide the floating
/// tab bar during text entry — a bottom-aligned floating bar otherwise rides the keyboard up
/// and floats over it (`.ignoresSafeArea(.keyboard)` doesn't pin a ZStack-aligned child).
@Observable
@MainActor
final class KeyboardObserver {
    var isVisible = false
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []

    init() {
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(forName: UIResponder.keyboardWillShowNotification,
                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isVisible = true }
        })
        tokens.append(nc.addObserver(forName: UIResponder.keyboardWillHideNotification,
                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isVisible = false }
        })
    }

    deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }
}
