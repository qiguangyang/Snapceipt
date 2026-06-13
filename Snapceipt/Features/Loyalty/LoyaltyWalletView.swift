import SwiftUI
import SwiftData

/// Full-screen loyalty wallet: LbHeader, brand-gradient card tiles with a mini
/// barcode, member number + points; tap -> detail; LbFloatingCTA + EmptyArt.
/// Re-skins the header `+` / CTA to the active profile accent.
struct LoyaltyWalletView: View {
    let context: ModelContext
    let sync: any SyncEnqueuing
    let userId: String
    let profileId: String
    let onClose: () -> Void
    let onAdd: () -> Void
    let onOpenCard: (String) -> Void

    @Environment(\.accent) private var accent
    @State private var vm: LoyaltyWalletViewModel?

    var body: some View {
        ZStack(alignment: .bottom) {
            Palette.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                LbHeader(title: "Loyalty cards", onClose: onClose, onAdd: onAdd)
                if let vm {
                    if vm.cards.isEmpty {
                        Spacer()
                        EmptyArt()
                        Text("No cards yet").font(.ui(15)).foregroundStyle(Palette.ink3)
                            .padding(.top, 6)
                        Spacer()
                    } else {
                        ScrollView {
                            Text("Tap a card to show its barcode at the checkout")
                                .font(.ui(13)).foregroundStyle(Palette.ink2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 10)
                            LazyVStack(spacing: 14) {
                                ForEach(vm.cards) { card in
                                    Button { onOpenCard(card.id) } label: { tile(card) }
                                        .buttonStyle(.plain)
                                        .accessibilityIdentifier(AccessibilityID.loyaltyCardRowPrefix + card.id)
                                }
                            }
                            .padding(.horizontal, 18)
                            .padding(.bottom, 110)
                        }
                    }
                } else { Color.clear }
            }
            LbFloatingCTA(title: "Add a card", a11yId: AccessibilityID.loyaltyWalletAdd, action: onAdd)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.loyaltyWalletScreen)
        .transition(.opacity)
        .task {
            vm = LoyaltyWalletViewModel(context: context, sync: sync, userId: userId, profileId: profileId)
        }
    }

    @ViewBuilder private func tile(_ card: LoyaltyCard) -> some View {
        let c1 = Color(hex: LoyaltyBrand.hex(card.color1))
        let c2 = Color(hex: LoyaltyBrand.hex(card.color2))
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.brand).font(.ui(16, .bold)).foregroundStyle(.white)
                    if let sub = card.subBrand {
                        Text(sub).font(.ui(12, .semibold)).foregroundStyle(.white.opacity(0.85))
                    }
                }
                Spacer()
                if let label = card.pointsLabel {
                    Text(label).font(.ui(12, .semibold)).foregroundStyle(.white)
                        .padding(.vertical, 4).padding(.horizontal, 10)
                        .background(Color.white.opacity(0.2), in: Capsule())
                }
            }
            miniBarcode(card)
                .frame(height: 40)
                .frame(maxWidth: .infinity)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(card.number).font(.ui(13, .semibold)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)
        }
        .padding(16)
        .background(
            LinearGradient(colors: [c1, c2], startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(alignment: .topTrailing) {
                    Circle().fill(Color.white.opacity(0.08))
                        .frame(width: 110, height: 110)
                        .offset(x: 28, y: -28)
                }
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .shadow(color: c2.opacity(0.4), radius: 12, x: 0, y: 10)
    }

    /// A small rendered barcode (or evenly-spaced stripes when rendering fails).
    @ViewBuilder private func miniBarcode(_ card: LoyaltyCard) -> some View {
        if let f = card.format, let img = BarcodeRenderer.image(value: card.number, format: f, scale: 2) {
            Image(uiImage: img)
                .interpolation(.none)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(.horizontal, 8).padding(.vertical, 4)
        } else {
            HStack(spacing: 2) {
                ForEach(0..<28, id: \.self) { i in
                    Rectangle().fill(Palette.ink.opacity(i % 3 == 0 ? 0.9 : 0.45))
                        .frame(width: i % 4 == 0 ? 3 : 1.5)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
        }
    }
}
