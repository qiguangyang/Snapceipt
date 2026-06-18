import SwiftUI

/// Home "Snap a receipt" call-to-action — the design's `SnapCTA` feature variant:
/// a dark ink card with an "AI auto-sort" pill and copy on the left, and an accent
/// gradient panel with a frosted camera tile on the right. Opens the capture flow.
struct HomeSnapCTA: View {
    @Environment(\.accent) private var accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Icon(name: "sparkles", size: 14, color: accent.base, filled: true)
                        Text("AI auto-sort")
                            .font(.ui(11.5, .bold)).foregroundStyle(.white).tracking(0.2)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.white.opacity(0.12), in: Capsule())
                    .padding(.bottom, 10)

                    Text("Snap a receipt")
                        .font(.ui(20, .bold)).foregroundStyle(.white).tracking(-0.3)
                    Text("We'll read the total, GST & category for you.")
                        .font(.ui(13.5)).foregroundStyle(.white.opacity(0.6))
                        .padding(.top, 3)
                        .frame(maxWidth: 180, alignment: .leading)
                }
                .padding(.vertical, 18).padding(.leading, 18)
                .frame(maxWidth: .infinity, alignment: .leading)

                ZStack {
                    LinearGradient(colors: [accent.base, accent.deep],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.white.opacity(0.22))
                        .frame(width: 60, height: 60)
                        .overlay(Icon(name: "camera", size: 30, color: .white))
                }
                .frame(width: 116)
                .frame(maxHeight: .infinity)
            }
            .background(Palette.ink)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .cardShadow()
            .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.homeSnapCTA)
    }
}
