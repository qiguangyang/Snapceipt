import SwiftUI

/// One slice of the donut. `id` keeps SwiftUI/ForEach stable.
struct DonutSegment: Identifiable, Equatable {
    let id: String
    let value: Double
    let tint: Color
}

/// Pure geometry result for one arc (testable, no SwiftUI side effects).
struct DonutArcLayout: Equatable {
    let tint: Color
    let fraction: Double      // value / total
    let dashLength: CGFloat   // (fraction * C) - gap, clamped >= 0
    let dashOffset: CGFloat   // accumulated un-gapped length before this arc
}

struct DonutLayout: Equatable {
    let radius: CGFloat
    let circumference: CGFloat
    let arcs: [DonutArcLayout]
}

/// Single source of truth for the donut geometry. Non-generic so it is callable
/// directly (`DonutMath.layout(...)`) without inferring the `Donut` view's `Center`
/// generic — the view forwards to it and `DonutMathTests` exercises it.
enum DonutMath {
    /// 3pt gap between segments (matches theme.jsx `Math.max(len - 3, 0)`).
    static var gap: CGFloat { 3 }

    /// Pure, side-effect-free geometry. Unit-tested by DonutMathTests.
    static func layout(segments: [DonutSegment], size: CGFloat, thickness: CGFloat) -> DonutLayout {
        let r = (size - thickness) / 2
        let c = 2 * .pi * r
        let total = segments.reduce(0) { $0 + $1.value }
        let denom = total == 0 ? 1 : total
        var acc: CGFloat = 0
        var arcs: [DonutArcLayout] = []
        for s in segments {
            let fraction = s.value / denom
            let len = CGFloat(fraction) * c
            arcs.append(
                DonutArcLayout(
                    tint: s.tint,
                    fraction: fraction,
                    dashLength: max(len - gap, 0),
                    dashOffset: acc
                )
            )
            acc += len
        }
        return DonutLayout(radius: r, circumference: c, arcs: arcs)
    }
}

struct Donut<Center: View>: View {
    let segments: [DonutSegment]
    var size: CGFloat = 140
    var thickness: CGFloat = 20
    @ViewBuilder var center: () -> Center

    @State private var appeared = false

    private var layout: DonutLayout {
        DonutMath.layout(segments: segments, size: size, thickness: thickness)
    }

    var body: some View {
        ZStack {
            // Grey track ring.
            Circle()
                .stroke(Palette.line, lineWidth: thickness)
                .frame(width: layout.radius * 2, height: layout.radius * 2)

            // Accent arcs, -90deg start, rounded caps, animatable trim.
            ForEach(Array(layout.arcs.enumerated()), id: \.offset) { _, arc in
                Circle()
                    .trim(from: trimStart(arc), to: appeared ? trimEnd(arc) : trimStart(arc))
                    .stroke(
                        arc.tint,
                        style: StrokeStyle(lineWidth: thickness, lineCap: .round)
                    )
                    .frame(width: layout.radius * 2, height: layout.radius * 2)
                    .rotationEffect(.degrees(-90))
            }
            center()
        }
        .frame(width: size, height: size)
        .onAppear { withAnimation(.snap(0.7)) { appeared = true } }
    }

    /// Trim fractions are 0..1 of the full circle; offset/length are in points along C.
    private func trimStart(_ arc: DonutArcLayout) -> CGFloat {
        layout.circumference == 0 ? 0 : arc.dashOffset / layout.circumference
    }
    private func trimEnd(_ arc: DonutArcLayout) -> CGFloat {
        layout.circumference == 0 ? 0 : (arc.dashOffset + arc.dashLength) / layout.circumference
    }
}

extension Donut where Center == EmptyView {
    init(segments: [DonutSegment], size: CGFloat = 140, thickness: CGFloat = 20) {
        self.init(segments: segments, size: size, thickness: thickness) { EmptyView() }
    }
}

#Preview("Donut") {
    Donut(
        segments: [
            DonutSegment(id: "meals", value: 320, tint: Color(red: 0.91, green: 0.376, blue: 0.173)),
            DonutSegment(id: "software", value: 240, tint: Color(red: 0.482, green: 0.357, blue: 0.839)),
            DonutSegment(id: "fuel", value: 140, tint: Color(red: 0.184, green: 0.435, blue: 0.69)),
            DonutSegment(id: "office", value: 90, tint: Color(red: 0.055, green: 0.486, blue: 0.447)),
        ],
        size: 140,
        thickness: 20
    ) {
        VStack(spacing: 2) {
            Text("$790").font(.system(size: 22, weight: .bold)).monospacedDigit()
            Text("spent").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        }
    }
    .padding(40)
}
