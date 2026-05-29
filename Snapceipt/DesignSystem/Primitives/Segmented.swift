import SwiftUI

struct SegmentOption: Identifiable, Equatable {
    let id: String
    let label: String
}

/// Index of the selected option (fallback 0). Pure logic — unit tested.
func segmentIndex(_ selection: String, in options: [SegmentOption]) -> Int {
    options.firstIndex(where: { $0.id == selection }).map { Swift.max(0, $0) } ?? 0
}

/// Animated sliding segmented control: paper-2 track, paper thumb that slides .28s.
struct Segmented: View {
    let options: [SegmentOption]
    @Binding var selection: String

    var body: some View {
        GeometryReader { geo in
            let n = Swift.max(1, options.count)
            let pad: CGFloat = 4
            let thumbW = (geo.size.width - pad * 2) / CGFloat(n)
            let idx = segmentIndex(selection, in: options)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 999, style: .continuous).fill(Palette.paper2)
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(Palette.paper)
                    .shadow(color: Color.black.opacity(0.12), radius: 3, x: 0, y: 2)
                    .frame(width: thumbW, height: geo.size.height - pad * 2)
                    .offset(x: pad + thumbW * CGFloat(idx), y: 0)
                    .animation(.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.28), value: selection)
                HStack(spacing: 0) {
                    ForEach(options) { opt in
                        Button { selection = opt.id } label: {
                            Text(opt.label)
                                .font(.ui(14, .semibold))
                                .foregroundStyle(opt.id == selection ? Palette.ink : Palette.ink3)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, pad)
            }
        }
        .frame(height: 38)
    }
}

#if DEBUG
private struct SegmentedDemo: View {
    @State var sel = "expense"
    var body: some View {
        Segmented(options: [SegmentOption(id: "expense", label: "Expense"),
                            SegmentOption(id: "income", label: "Income")], selection: $sel)
            .frame(width: 260).padding().background(Palette.cream)
    }
}
#Preview("Segmented") { SegmentedDemo() }
#endif
