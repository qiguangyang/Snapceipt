import SwiftUI

/// Receipt thumbnail behind an animated scan line, with the 5 field-reveal chips
/// flipping pending→found as extraction resolves. Auto-advance is driven by the
/// view-model moving to `.review`; this view only animates while `.scanning`.
struct ScanStep: View {
    @Environment(\.accent) private var accent
    let image: UIImage?
    let draft: ExtractedReceipt?
    /// Dismisses the whole capture overlay (cancel affordance during scanning).
    let onClose: () -> Void

    @State private var scanY: CGFloat = 0
    @State private var revealed = 0

    private let chips = ["Merchant", "Date", "GST", "Total", "Category"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                CaptureCloseButton(onClose: onClose)
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 12)

            scanBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream)
        .onAppear { animate() }
    }

    private var scanBody: some View {
        VStack(spacing: 22) {
            Text("Reading your receipt…")
                .font(.display(20))
                .foregroundStyle(Palette.ink)
                .accessibilityIdentifier(AccessibilityID.captureScanTitle)

            ZStack {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Palette.paper)
                    .frame(width: 220, height: 300)
                    .cardShadow()
                if let image {
                    Image(uiImage: image)
                        .resizable().scaledToFill()
                        .frame(width: 220, height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                }
                // Scan line.
                Rectangle()
                    .fill(LinearGradient(colors: [accent.base.opacity(0), accent.base, accent.base.opacity(0)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: 220, height: 3)
                    .offset(y: scanY)
            }
            .frame(width: 220, height: 300)

            HStack(spacing: 8) {
                ForEach(Array(chips.enumerated()), id: \.offset) { idx, label in
                    let found = idx < revealed
                    Text(label)
                        .font(.ui(11.5, .semibold))
                        .foregroundStyle(found ? .white : Palette.ink3)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(found ? accent.base : Palette.paper2,
                                    in: Capsule())
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: found)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func animate() {
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            scanY = 130
        }
        // Stagger the chip reveals for feel; the VM advances to Review when done.
        for i in 1...chips.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18 * Double(i)) {
                revealed = i
            }
        }
    }
}
