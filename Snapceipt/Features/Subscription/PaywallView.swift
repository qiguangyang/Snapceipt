import SwiftUI
import StoreKit

/// Paywall for Snapceipt Pro. Presented as a sheet when a free user taps a Pro
/// feature. Shows two subscription products (loaded from StoreKit / .storekit config),
/// a 14-day free trial badge when available, and links to Terms + Privacy as required
/// by App Store Review Guidelines §3.1.2.
struct PaywallView: View {
    @Environment(StoreKitService.self) private var storekit
    @Environment(EntitlementStore.self) private var entitlement
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent

    @State private var isPurchasing = false
    @State private var isRestoring = false

    private let benefits: [(icon: String, text: String)] = [
        ("doc.text.magnifyingglass", "BAS-ready export & accountant pack"),
        ("doc.richtext",             "Quotes & invoices"),
        ("car.fill",                 "Vehicle & WFH logbooks"),
        ("envelope.badge",           "Email-in receipts"),
    ]

    var body: some View {
        ZStack {
            Palette.cream.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    headline
                    benefitsList
                    productButtons
                    restoreButton
                    footer
                }
                .padding(.horizontal, 24)
                .padding(.top, 32)
                .padding(.bottom, 48)
            }
        }
        .task { await storekit.loadProducts() }
    }

    // MARK: - Sections

    private var headline: some View {
        VStack(spacing: 8) {
            Text("Snapceipt Pro")
                .font(.ui(28, .bold))
                .foregroundStyle(Palette.ink)
                .accessibilityIdentifier(AccessibilityID.paywallTitle)
            Text("Unlock powerful tools for your business")
                .font(.ui(15))
                .foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
        }
    }

    private var benefitsList: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(benefits, id: \.text) { benefit in
                HStack(spacing: 12) {
                    Image(systemName: benefit.icon)
                        .frame(width: 24)
                        .foregroundStyle(accent.base)
                    Text(benefit.text)
                        .font(.ui(15))
                        .foregroundStyle(Palette.ink)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Palette.paper2, in: RoundedRectangle(cornerRadius: 14))
    }

    private var productButtons: some View {
        VStack(spacing: 12) {
            if storekit.products.isEmpty {
                ProgressView().tint(accent.base)
            } else {
                ForEach(storekit.products, id: \.id) { product in
                    productButton(product)
                }
            }
        }
    }

    @ViewBuilder private func productButton(_ product: Product) -> some View {
        let isMonthly = product.id == StoreKitService.ProductID.monthly
        Button {
            guard !isPurchasing else { return }
            isPurchasing = true
            Task {
                let outcome = await storekit.purchase(product)
                isPurchasing = false
                if outcome == .success { dismiss() }
            }
        } label: {
            VStack(spacing: 4) {
                Text("\(product.displayName) — \(product.displayPrice)")
                    .font(.ui(16, .semibold))
                    .foregroundStyle(.white)
                if product.subscription?.introductoryOffer != nil {
                    Text("14-day free trial, then \(product.displayPrice)/\(isMonthly ? "mo" : "yr")")
                        .font(.ui(12))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(accent.base, in: RoundedRectangle(cornerRadius: 14))
        }
        .disabled(isPurchasing)
        .accessibilityIdentifier(isMonthly ? AccessibilityID.paywallBuyMonthly : AccessibilityID.paywallBuyYearly)
    }

    private var restoreButton: some View {
        Button {
            guard !isRestoring else { return }
            isRestoring = true
            Task {
                await storekit.restore()
                isRestoring = false
                if entitlement.isPro { dismiss() }
            }
        } label: {
            if isRestoring {
                ProgressView().tint(accent.base)
            } else {
                Text("Restore Purchases")
                    .font(.ui(14, .semibold))
                    .foregroundStyle(accent.base)
            }
        }
        .accessibilityIdentifier(AccessibilityID.paywallRestore)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Link("Terms", destination: URL(string: "https://snapceipt.cc/terms")!)
            Text("·").foregroundStyle(Palette.ink3)
            Link("Privacy", destination: URL(string: "https://snapceipt.cc/privacy")!)
        }
        .font(.ui(13))
        .foregroundStyle(Palette.ink3)
    }
}

#Preview {
    PaywallView()
        .environment(StoreKitService())
        .environment(EntitlementStore())
}
