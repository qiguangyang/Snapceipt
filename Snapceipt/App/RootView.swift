import SwiftUI

/// Placeholder root. Replaced by the real tab-bar shell (TabBar + Router + overlays)
/// in a later foundation task. Kept intentionally token-free so it builds before
/// the DesignSystem exists.
struct RootView: View {
    var body: some View {
        ZStack {
            Color(red: 0xFB / 255, green: 0xF6 / 255, blue: 0xF0 / 255) // cream #FBF6F0
                .ignoresSafeArea()
            Text("Snapceipt")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Color(red: 0x21 / 255, green: 0x1C / 255, blue: 0x18 / 255)) // ink #211C18
        }
    }
}

#Preview {
    RootView()
}
