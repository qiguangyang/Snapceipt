import SwiftUI

// MARK: - Central easing

extension Animation {
    /// The app-wide easing curve. Mirrors CSS cubic-bezier(.22,.61,.36,1).
    static let snap = Animation.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.34)

    /// Same curve with a caller-chosen duration (sc-fade-up .42, Progress .6, Donut .7, etc.).
    static func snap(_ duration: Double) -> Animation {
        .timingCurve(0.22, 0.61, 0.36, 1, duration: duration)
    }

    /// sc-pop-in spring overshoot: cubic-bezier(.34,1.56,.64,1), ~.5s.
    static func scPopIn(_ duration: Double = 0.5) -> Animation {
        .timingCurve(0.34, 1.56, 0.64, 1, duration: duration)
    }
}

// MARK: - Named transitions

extension AnyTransition {
    /// sc-fade-up: opacity 0 + translateY(10) -> settle. Used by staggered list/section enters.
    static var scFadeUp: AnyTransition {
        .modifier(
            active: ScOffsetFade(y: 10, opacity: 0),
            identity: ScOffsetFade(y: 0, opacity: 1)
        )
    }

    /// sc-rise: opacity 0 + translateY(14) + scale .98 -> settle. Used by bottom sheets.
    static var scRise: AnyTransition {
        .modifier(
            active: ScRise(y: 14, scale: 0.98, opacity: 0),
            identity: ScRise(y: 0, scale: 1, opacity: 1)
        )
    }
}

private struct ScOffsetFade: ViewModifier {
    let y: CGFloat
    let opacity: Double
    func body(content: Content) -> some View {
        content.opacity(opacity).offset(y: y)
    }
}

private struct ScRise: ViewModifier {
    let y: CGFloat
    let scale: CGFloat
    let opacity: Double
    func body(content: Content) -> some View {
        content.opacity(opacity).scaleEffect(scale).offset(y: y)
    }
}

// MARK: - sc-ring (success halo pulse): scale .6 -> 1.5, opacity .55 -> 0

struct ScRingModifier: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .scaleEffect(active ? 1.5 : 0.6)
            .opacity(active ? 0 : 0.55)
            .animation(.easeOut(duration: 1.1).delay(0.1), value: active)
    }
}

extension View {
    /// Drive the success-ring halo: flip `active` to true on appear.
    func scRing(active: Bool) -> some View { modifier(ScRingModifier(active: active)) }
}

// MARK: - sc-check: animatable checkmark draw (stroke-dashoffset 48 -> 0)

/// The d-string 'M5 12.5 10 17.5 19.5 7' from theme.jsx ICONS.check, on a 0..24 grid,
/// drawn by trimming from 0..trimEnd so it animates like the CSS stroke-dashoffset draw.
struct ScCheckShape: Shape {
    var trimEnd: CGFloat = 1
    var animatableData: CGFloat {
        get { trimEnd }
        set { trimEnd = newValue }
    }
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24, sy = rect.height / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
        var full = Path()
        full.move(to: p(5, 12.5))
        full.addLine(to: p(10, 17.5))
        full.addLine(to: p(19.5, 7))
        return full.trimmedPath(from: 0, to: trimEnd)
    }
}

// MARK: - sc-confetti piece: translateY 0 -> 220, rotate 0 -> 420deg, opacity 1 -> 0

struct ScConfettiPiece: View {
    let color: Color
    let index: Int
    @State private var animate = false
    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: 8, height: 12)
            .rotationEffect(.degrees(animate ? 420 : 0))
            .offset(y: animate ? 220 : 0)
            .opacity(animate ? 0 : 1)
            .onAppear {
                withAnimation(
                    .easeIn(duration: 1.0 + Double(index % 5) * 0.18)
                        .delay(Double(index % 4) * 0.06)
                ) { animate = true }
            }
    }
}

#Preview("Animations") {
    VStack(spacing: 28) {
        ScCheckShape()
            .stroke(Color(red: 0.122, green: 0.616, blue: 0.42),
                    style: StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round))
            .frame(width: 50, height: 50)
        Circle()
            .fill(Color(red: 0.122, green: 0.616, blue: 0.42))
            .frame(width: 96, height: 96)
            .overlay(Circle().fill(Color(red: 0.122, green: 0.616, blue: 0.42)).scRing(active: true))
        ZStack {
            ForEach(0..<14, id: \.self) { i in
                ScConfettiPiece(
                    color: [Color.orange, .green, .purple, .yellow, .blue][i % 5],
                    index: i
                )
                .offset(x: CGFloat(-44 + i * 6))
            }
        }
        .frame(height: 120)
    }
    .padding(40)
}
