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
                // 165deg gradient (c1 -> c2): near-vertical, tilted slightly.
                let c1 = Color(hex: LoyaltyBrand.hex(card.color1))
                let c2 = Color(hex: LoyaltyBrand.hex(card.color2))
                LinearGradient(colors: [c1, c2],
                               startPoint: UnitPoint(x: 0.15, y: 0), endPoint: UnitPoint(x: 0.85, y: 1))
                    .ignoresSafeArea()
                VStack(spacing: 18) {
                    header(card)
                    Spacer()
                    VStack(spacing: 4) {
                        Text(card.brand).font(.display(30, .bold)).foregroundStyle(.white)
                        if let sub = card.subBrand {
                            Text(sub).font(.ui(14, .semibold)).foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    barcodePanel(card)
                    HStack(spacing: 7) {
                        Icon(name: "sparkles", size: 14, color: .white.opacity(0.85))
                        Text("Screen brightness boosted for scanning")
                            .font(.ui(12)).foregroundStyle(.white.opacity(0.8))
                    }
                    Spacer()
                    footer(card, color2: c2)
                }
                .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 30)
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

    /// Top chrome: close circle (left) + points pill (right).
    private func header(_ card: LoyaltyCard) -> some View {
        HStack {
            Button(action: onClose) {
                Circle().fill(Color.white.opacity(0.2)).background(.ultraThinMaterial, in: Circle())
                    .frame(width: 40, height: 40)
                    .overlay(Icon(name: "close", size: 20, color: .white))
            }
            .buttonStyle(.plain)
            Spacer()
            if let label = card.pointsLabel {
                Text(label).font(.ui(12, .semibold)).foregroundStyle(.white)
                    .padding(.vertical, 6).padding(.horizontal, 12)
                    .background(Color.white.opacity(0.2), in: Capsule())
            }
        }
        .padding(.top, 14)
    }

    @ViewBuilder private func barcodePanel(_ card: LoyaltyCard) -> some View {
        VStack(spacing: 14) {
            ZStack {
                if let f = card.format, let img = BarcodeRenderer.image(value: card.number, format: f, scale: 6) {
                    Image(uiImage: img)
                        .interpolation(.none)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                } else {
                    // Number-only fallback (proprietary / unsupported / invalid).
                    Text(card.number).font(.display(22, .bold)).monospacedDigit()
                        .foregroundStyle(Palette.ink)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 120)
            Text(card.number).font(.display(17, .bold)).monospacedDigit()
                .kerning(2).foregroundStyle(Palette.ink)
        }
        .padding(20)
        .frame(maxWidth: 320)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 22, x: 0, y: 16)
        .accessibilityIdentifier(AccessibilityID.loyaltyDetailBarcode)
    }

    private func footer(_ card: LoyaltyCard, color2: Color) -> some View {
        HStack(spacing: 12) {
            ShareLink(item: card.number) {
                HStack(spacing: 7) {
                    Icon(name: "share", size: 16, color: color2)
                    Text("Share").font(.ui(15, .semibold)).foregroundStyle(color2)
                }
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(Color.white.opacity(0.95), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            Button(action: onClose) {
                Text("Done").font(.ui(15, .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
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
