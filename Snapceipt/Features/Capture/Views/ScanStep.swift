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
    /// Dark viewfinder backdrop (#0c0a09) — matches the native scanner feel.
    private let backdrop = Color(hex: 0x0C0A09)
    private let receiptW: CGFloat = 220
    private let receiptH: CGFloat = 300

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
        .background(backdrop)
        .onAppear { animate() }
    }

    private var scanBody: some View {
        VStack(spacing: 30) {
            receiptPreview

            // Title BELOW the receipt: leading filled accent sparkles + display(17) white.
            HStack(spacing: 9) {
                Icon(name: "sparkles", size: 20, color: accent.base, filled: true)
                Text("Reading your receipt…")
                    .font(.display(17))
                    .foregroundStyle(.white)
            }
            .accessibilityIdentifier(AccessibilityID.captureScanTitle)

            chipRows
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var receiptPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.paper)
                .frame(width: receiptW, height: receiptH)
                .cardShadow()
            if let image {
                // Fit (not fill) so the WHOLE scanned receipt shows — fill clipped the tall
                // receipt's top (merchant) and bottom (date). Letterbox shows the paper behind.
                Image(uiImage: image)
                    .resizable().scaledToFit()
                    .frame(width: receiptW, height: receiptH)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            }
            // Glowing scan line — rounded, extends ~4pt past each edge, glow shadow.
            Capsule()
                .fill(LinearGradient(colors: [accent.base.opacity(0), accent.base, accent.base.opacity(0)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: receiptW + 8, height: 3)
                .shadow(color: accent.base, radius: 8)
                .offset(y: scanY)
        }
        .frame(width: receiptW, height: receiptH)
        // Accent corner-glow frame inset ~10pt around the receipt.
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(accent.base.opacity(0.5), lineWidth: 2)
                .padding(-10)
        )
    }

    /// Field chips, wrapped over two rows (3 + 2) so they never overflow.
    private var chipRows: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { chip(at: $0) }
            }
            HStack(spacing: 8) {
                ForEach(3..<5, id: \.self) { chip(at: $0) }
            }
        }
        .frame(maxWidth: 280)
    }

    @ViewBuilder
    private func chip(at idx: Int) -> some View {
        let found = idx < revealed
        HStack(spacing: 6) {
            if found {
                Icon(name: "check", size: 13, color: accent.base, lineWidth: 2.6)
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white.opacity(0.5))
            }
            Text(chips[idx])
                .font(.ui(12.5, .semibold))
                .foregroundStyle(found ? .white : .white.opacity(0.35))
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(
            Capsule().fill(found ? Color.white.opacity(0.12) : Color.white.opacity(0.04))
        )
        .overlay(
            Capsule().stroke(found ? accent.base : .clear, lineWidth: 1)
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: found)
    }

    private func animate() {
        // Glowing scan line sweeps the receipt; retimed to ~1.4s like the design.
        scanY = -(receiptH / 2) + 4
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            scanY = (receiptH / 2) - 4
        }
        // Stagger the chip reveals for feel; the VM advances to Review when done.
        for i in 1...chips.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18 * Double(i)) {
                revealed = i
            }
        }
    }
}
