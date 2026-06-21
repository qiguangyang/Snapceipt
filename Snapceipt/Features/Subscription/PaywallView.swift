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
    /// The plan the user has selected; the CTA buys this one. Defaults to the
    /// highlighted (best-value) plan once products load.
    @State private var selectedID: String?
    /// Set after a delay while still `.loading` so a slow/stuck network surfaces a
    /// Retry escape hatch beneath the spinner — without flipping load state (a late
    /// success still wins). Resets each time the loading view re-appears.
    @State private var slowLoad = false

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
        .overlay(alignment: .topTrailing) { closeButton }
        .task { await storekit.loadProducts() }
    }

    // MARK: - Sections

    /// Explicit dismiss control: swipe-to-dismiss alone isn't discoverable for
    /// VoiceOver / Switch Control users (and App Review has flagged paywalls with no
    /// visible close affordance).
    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Palette.ink2)
                .frame(width: 32, height: 32)
                .background(Palette.paper2, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
        .padding(.trailing, 16)
        .accessibilityLabel("Close")
        .accessibilityIdentifier(AccessibilityID.paywallClose)
    }

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

    @ViewBuilder private var productButtons: some View {
        switch storekit.productsState {
        case .loading:
            loadingState
        case .loaded(let products):
            planSelector(plans(from: products)) { id in
                if let product = products.first(where: { $0.id == id }) { buy(product) }
            }
        case .empty:
            // Store responded but vended nothing → App Store Connect isn't serving the
            // products (agreement/availability). Generic copy; cause is in the os_log.
            loadProblem("Couldn't load plans right now.")
        case .failed:
            loadProblem("Plans are temporarily unavailable.")
        }
    }

    /// Spinner while products load. After a delay, also reveals a Retry button so a
    /// stuck network never dead-ends on a forever-spinner — state is left untouched,
    /// so a slow-but-valid load still flips to the buttons on its own.
    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().tint(accent.base)
            if slowLoad {
                Button {
                    Task { await storekit.loadProducts() }
                } label: {
                    Text("Taking a while — Retry")
                        .font(.ui(13, .semibold))
                        .foregroundStyle(accent.base)
                }
                .accessibilityIdentifier(AccessibilityID.paywallRetry)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .accessibilityIdentifier(AccessibilityID.paywallLoading)
        .task {
            slowLoad = false
            try? await Task.sleep(for: .seconds(12))
            slowLoad = true
        }
    }

    /// Empty/failed message + Retry. Restore/Terms/Privacy stay reachable below it.
    private func loadProblem(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .font(.ui(15, .semibold))
                .foregroundStyle(Palette.alert)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier(AccessibilityID.paywallLoadError)
            Button {
                Task { await storekit.loadProducts() }
            } label: {
                Text("Retry")
                    .font(.ui(16, .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(accent.base, in: RoundedRectangle(cornerRadius: 14))
            }
            .accessibilityIdentifier(AccessibilityID.paywallRetry)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(Palette.paper2, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Plan selector (cards + CTA)

    /// Selectable plan cards + a single CTA that buys the selected plan. Best-value plan
    /// is selected by default.
    @ViewBuilder private func planSelector(_ plans: [PaywallPlan],
                                           purchase: @escaping (String) -> Void = { _ in }) -> some View {
        let current = plans.first { $0.id == selectedID } ?? plans.first { $0.highlight } ?? plans.first
        VStack(spacing: 12) {
            ForEach(plans) { plan in
                planCard(plan, isSelected: plan.id == current?.id)
                    .onTapGesture { withAnimation(.snappy(duration: 0.18)) { selectedID = plan.id } }
            }
            if let current {
                ctaButton(current, purchase: purchase).padding(.top, 4)
            }
        }
        .onAppear {
            if selectedID == nil { selectedID = (plans.first { $0.highlight } ?? plans.last)?.id }
        }
    }

    @ViewBuilder private func planCard(_ plan: PaywallPlan, isSelected: Bool) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(plan.title).font(.ui(16, .bold)).foregroundStyle(Palette.ink)
                    if let badge = plan.savingsBadge {
                        Text(badge)
                            .font(.ui(10.5, .bold)).tracking(0.3).foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(accent.base, in: Capsule())
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(plan.price).font(.ui(25, .bold)).foregroundStyle(Palette.ink)
                    Text("/ \(plan.periodNoun)").font(.ui(14, .medium)).foregroundStyle(Palette.ink2)
                }
                if let perMonth = plan.perMonth {
                    Text("\(perMonth)/mo · billed annually").font(.ui(12.5)).foregroundStyle(Palette.ink2)
                }
                if plan.hasTrial {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.seal.fill").font(.ui(12)).foregroundStyle(accent.base)
                        Text("14-day free trial included").font(.ui(12.5, .semibold)).foregroundStyle(accent.deep)
                    }
                }
            }
            Spacer(minLength: 8)
            ZStack {
                Circle().strokeBorder(isSelected ? accent.base : Palette.ink3, lineWidth: 2)
                if isSelected { Circle().fill(accent.base).padding(5) }
            }
            .frame(width: 24, height: 24)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? accent.soft : Palette.paper, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(isSelected ? accent.base : Palette.line, lineWidth: isSelected ? 2 : 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .accessibilityIdentifier(plan.id == StoreKitService.ProductID.monthly
                                 ? AccessibilityID.paywallBuyMonthly : AccessibilityID.paywallBuyYearly)
    }

    @ViewBuilder private func ctaButton(_ plan: PaywallPlan, purchase: @escaping (String) -> Void) -> some View {
        VStack(spacing: 8) {
            Button {
                guard !isPurchasing else { return }
                purchase(plan.id)
            } label: {
                HStack(spacing: 8) {
                    if isPurchasing { ProgressView().tint(.white) }
                    Text(plan.hasTrial ? "Start 14-day free trial" : "Subscribe")
                        .font(.ui(17, .semibold)).foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 17)
                .background(accent.base, in: RoundedRectangle(cornerRadius: 16))
            }
            .disabled(isPurchasing)
            .accessibilityIdentifier(AccessibilityID.paywallSubscribe)
            Text(plan.hasTrial
                 ? "Then \(plan.price)/\(plan.periodNoun) · cancel anytime"
                 : "\(plan.price)/\(plan.periodNoun) · cancel anytime")
                .font(.ui(12)).foregroundStyle(Palette.ink3)
        }
    }

    /// Buy a product, dismissing on success. Shared by the CTA.
    private func buy(_ product: Product) {
        guard !isPurchasing else { return }
        isPurchasing = true
        Task {
            let outcome = await storekit.purchase(product)
            isPurchasing = false
            if outcome == .success { dismiss() }
        }
    }

    /// Map loaded StoreKit products to display plans (annual first, with per-month +
    /// savings derived from the monthly price).
    private func plans(from products: [Product]) -> [PaywallPlan] {
        let monthly = products.first { $0.id == StoreKitService.ProductID.monthly }
        let yearly = products.first { $0.id == StoreKitService.ProductID.yearly }
        var result: [PaywallPlan] = []
        if let y = yearly {
            var badge: String?
            if let m = monthly?.price {
                let md = Double(truncating: m as NSNumber), yd = Double(truncating: y.price as NSNumber)
                if md > 0 {
                    let pct = Int((100 * (1 - yd / (md * 12))).rounded())
                    if pct > 0 { badge = "SAVE \(pct)%" }
                }
            }
            result.append(PaywallPlan(
                id: y.id, title: "Annual", price: y.displayPrice, periodNoun: "year",
                perMonth: (y.price / 12).formatted(y.priceFormatStyle),
                savingsBadge: badge, highlight: true, hasTrial: y.subscription?.introductoryOffer != nil))
        }
        if let m = monthly {
            result.append(PaywallPlan(
                id: m.id, title: "Monthly", price: m.displayPrice, periodNoun: "month",
                perMonth: nil, savingsBadge: nil, highlight: false,
                hasTrial: m.subscription?.introductoryOffer != nil))
        }
        return result
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
        VStack(spacing: 12) {
            // Auto-renewal disclosure required by App Review Guideline 3.1.2.
            Text("Subscription automatically renews unless cancelled at least 24 hours before the end of the current period. Manage or cancel anytime in your App Store account settings.")
                .font(.ui(11.5))
                .foregroundStyle(Palette.ink3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(AccessibilityID.paywallAutoRenewDisclosure)
            HStack(spacing: 16) {
                Link("Terms", destination: URL(string: "https://snapceipt.cc/terms")!)
                Text("·").foregroundStyle(Palette.ink3)
                Link("Privacy", destination: URL(string: "https://snapceipt.cc/privacy")!)
            }
            .font(.ui(13))
            .foregroundStyle(Palette.ink3)
        }
    }
}

/// View model for a paywall plan card — decoupled from `Product` so the layout can be
/// previewed/screenshotted with sample data.
struct PaywallPlan: Identifiable {
    let id: String
    let title: String          // "Annual" / "Monthly"
    let price: String          // localized display price, e.g. "$49.00"
    let periodNoun: String     // "year" / "month"
    let perMonth: String?      // yearly equivalent, e.g. "$4.08"; nil for monthly
    let savingsBadge: String?  // e.g. "SAVE 32%"; nil when none
    let highlight: Bool        // best-value plan (default-selected)
    let hasTrial: Bool
}

#Preview {
    PaywallView()
        .environment(StoreKitService())
        .environment(EntitlementStore())
}
