import SwiftUI
import UIKit

/// Maxes screen brightness on appear (so a barcode scans at the POS) and restores
/// the captured value on disappear. Applied to the loyalty card detail screen only.
struct ScreenBrightnessBoost: ViewModifier {
    @State private var saved: CGFloat?

    func body(content: Content) -> some View {
        content
            .onAppear {
                if saved == nil { saved = UIScreen.main.brightness }
                UIScreen.main.brightness = 1.0
            }
            .onDisappear {
                if let saved { UIScreen.main.brightness = saved }
            }
    }
}

extension View {
    /// Boost screen brightness to max while this view is visible.
    func screenBrightnessBoost() -> some View { modifier(ScreenBrightnessBoost()) }
}
