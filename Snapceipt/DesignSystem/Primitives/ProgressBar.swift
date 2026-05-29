import SwiftUI

/// Rounded progress track (line) + tinted fill; height 8, animates width over .6s.
struct ProgressBar: View {
    var value: Double
    var max: Double = 1
    var tint: Color
    var height: CGFloat = 8
    private var fraction: Double { max <= 0 ? 0 : min(1, Swift.max(0, value / max)) }
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.line)
                Capsule().fill(tint).frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: height)
        .animation(.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.6), value: fraction)
    }
}

#if DEBUG
#Preview("ProgressBar") {
    ProgressBar(value: 64.85, max: 600, tint: Color(hex: 0xE8602C))
        .frame(width: 240).padding().background(Palette.cream)
}
#endif
