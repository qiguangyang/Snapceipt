import SwiftUI
import SwiftData

/// Immersive loyalty-card detail: the card's own gradient fills the screen, a white
/// panel shows the rendered barcode (or a number-only fallback), member number, a
/// brightness boost for scanning, and Share (member number) + Done. The card is
/// fetched by id; if missing, the view dismisses.
struct LoyaltyCardDetailView: View {
    let context: ModelContext
    let cardId: String
    let onClose: () -> Void

    @State private var card: LoyaltyCard?

    var body: some View {
        ZStack {
            if let card {
                let c1 = Color(hex: LoyaltyBrand.hex(card.color1))
                let c2 = Color(hex: LoyaltyBrand.hex(card.color2))
                LinearGradient(colors: [c1, c2], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
                VStack(spacing: 18) {
                    header(card)
                    Spacer()
                    barcodePanel(card)
                    Text(card.number).font(.display(18, .bold)).monospacedDigit()
                        .kerning(1.5).foregroundStyle(.white)
                    Text("Screen brightness boosted for scanning")
                        .font(.ui(12)).foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    footer(card)
                }
                .padding(.horizontal, 24).padding(.vertical, 30)
            } else {
                Palette.cream.ignoresSafeArea()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.loyaltyDetailScreen)
        .transition(.opacity)
        .screenBrightnessBoost()
        .task { load() }
    }

    private func header(_ card: LoyaltyCard) -> some View {
        VStack(spacing: 2) {
            Text(card.brand).font(.display(24, .bold)).foregroundStyle(.white)
            if let sub = card.subBrand {
                Text(sub).font(.ui(13, .semibold)).foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(.top, 30)
    }

    @ViewBuilder private func barcodePanel(_ card: LoyaltyCard) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white)
            if let f = card.format, let img = BarcodeRenderer.image(value: card.number, format: f, scale: 6) {
                Image(uiImage: img)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(20)
            } else {
                // Number-only fallback (proprietary / unsupported / invalid).
                Text(card.number).font(.display(22, .bold)).monospacedDigit()
                    .foregroundStyle(Palette.ink).padding(24)
            }
        }
        .frame(maxWidth: 320)
        .frame(height: 160)
        .accessibilityIdentifier(AccessibilityID.loyaltyDetailBarcode)
    }

    private func footer(_ card: LoyaltyCard) -> some View {
        HStack(spacing: 12) {
            ShareLink(item: card.number) {
                HStack(spacing: 6) {
                    Icon(name: "arrowRight", size: 16, color: .white)
                    Text("Share").font(.ui(15, .semibold)).foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            Button(action: onClose) {
                Text("Done").font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.loyaltyDetailDone)
        }
    }

    private func load() {
        let id = cardId
        var d = FetchDescriptor<LoyaltyCard>(predicate: #Predicate { $0.id == id && $0.deletedAt == nil })
        d.fetchLimit = 1
        card = (try? context.fetch(d))?.first
    }
}
