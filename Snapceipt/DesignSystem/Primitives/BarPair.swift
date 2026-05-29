import SwiftUI

/// One month's income vs expense pair.
struct BarPairDatum: Identifiable, Equatable {
    let id = UUID()
    let label: String
    let income: Double
    let expense: Double
}

struct BarPair: View {
    let data: [BarPairDatum]
    var height: CGFloat = 120

    @Environment(\.accent) private var accent
    @State private var appeared = false

    /// Label row reserved at the bottom of each column (matches theme.jsx `height - 22`).
    static var labelRow: CGFloat { 22 }

    /// Pure, side-effect-free bar geometry. Unit-tested by BarPairMathTests.
    static func barHeights(data: [BarPairDatum], height: CGFloat) -> [(income: CGFloat, expense: CGFloat)] {
        guard !data.isEmpty else { return [] }
        let area = height - labelRow
        let maxVal = max(data.flatMap { [$0.income, $0.expense] }.max() ?? 1, 1)
        return data.map { d in
            (
                income: CGFloat(d.income / maxVal) * area,
                expense: CGFloat(d.expense / maxVal) * area
            )
        }
    }

    var body: some View {
        let heights = BarPair.barHeights(data: data, height: height)
        HStack(alignment: .bottom, spacing: 14) {
            ForEach(Array(data.enumerated()), id: \.element.id) { idx, d in
                VStack(spacing: 7) {
                    HStack(alignment: .bottom, spacing: 4) {
                        bar(heights[idx].income, color: Palette.income)
                        bar(heights[idx].expense, color: accent.base)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: height - BarPair.labelRow, alignment: .bottom)
                    Text(d.label)
                        .font(.ui(11, .semibold))
                        .foregroundStyle(Palette.ink3)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height)
        .padding(.horizontal, 2)
        .onAppear { withAnimation(.snap(0.6)) { appeared = true } }
    }

    private func bar(_ h: CGFloat, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(color)
            .frame(width: 11, height: appeared ? h : 0)
    }
}

#Preview("BarPair") {
    BarPair(data: [
        BarPairDatum(label: "Jan", income: 4800, expense: 3100),
        BarPairDatum(label: "Feb", income: 5200, expense: 2700),
        BarPairDatum(label: "Mar", income: 4100, expense: 3600),
        BarPairDatum(label: "Apr", income: 6050, expense: 2900),
        BarPairDatum(label: "May", income: 5050, expense: 2480),
    ])
    .padding(40)
    .environment(\.accent, AccentPalette.personal)
}
