import SwiftUI

/// Variant hook for future empty states (only `.receipt` is shipped in foundation).
enum EmptyArtKind {
    case receipt
}

struct EmptyArt: View {
    var kind: EmptyArtKind = .receipt
    var size: CGFloat = 132

    @Environment(\.accent) private var accent

    var body: some View {
        // Work in the 132-unit SVG coordinate space, then scale to `size`.
        let s = size / 132
        ZStack {
            // Accent-soft backing circle, r60 centered at (66,66).
            Circle()
                .fill(accent.soft)
                .frame(width: 120 * s, height: 120 * s)

            // Receipt card: 44x64 r6, white fill, accent stroke 2.4, rotated -6deg.
            ZStack {
                RoundedRectangle(cornerRadius: 6 * s)
                    .fill(Color.white)
                RoundedRectangle(cornerRadius: 6 * s)
                    .stroke(accent.base, lineWidth: 2.4 * s)
                // Three rule lines (52->80, 52->80, 52->72) at y 48/58/68 on the 132 grid.
                Path { p in
                    p.move(to: CGPoint(x: 8 * s, y: 14 * s));  p.addLine(to: CGPoint(x: 36 * s, y: 14 * s))
                    p.move(to: CGPoint(x: 8 * s, y: 24 * s));  p.addLine(to: CGPoint(x: 36 * s, y: 24 * s))
                    p.move(to: CGPoint(x: 8 * s, y: 34 * s));  p.addLine(to: CGPoint(x: 28 * s, y: 34 * s))
                }
                .stroke(accent.base,
                        style: StrokeStyle(lineWidth: 2.2 * s, lineCap: .round))
                .opacity(0.55)
            }
            .frame(width: 44 * s, height: 64 * s)
            .rotationEffect(.degrees(-6))

            // Plus badge: accent circle r17 at (92,92), white plus.
            ZStack {
                Circle().fill(accent.base)
                Path { p in
                    p.move(to: CGPoint(x: 17 * s, y: 10 * s)); p.addLine(to: CGPoint(x: 17 * s, y: 24 * s))
                    p.move(to: CGPoint(x: 10 * s, y: 17 * s)); p.addLine(to: CGPoint(x: 24 * s, y: 17 * s))
                }
                .stroke(Color.white,
                        style: StrokeStyle(lineWidth: 2.8 * s, lineCap: .round))
            }
            .frame(width: 34 * s, height: 34 * s)
            // Badge center sits at (92,92); circle (66,66) is at the ZStack center, so offset = +26.
            .offset(x: 26 * s, y: 26 * s)
        }
        .frame(width: size, height: size)
    }
}

#Preview("EmptyArt") {
    VStack(spacing: 28) {
        EmptyArt().environment(\.accent, AccentPalette.personal)
        EmptyArt(size: 96).environment(\.accent, AccentPalette.business)
    }
    .padding(40)
    .background(Palette.cream)
}
