import SwiftUI

/// The designed editable review card: total + GST pill, the AI-suggestion banner,
/// the confidence badge (shown iff !needsReview), editable merchant/date/category/
/// payment/tax-label, a Personal/Business profile toggle that re-skins live, a
/// read-only line-items list, disabled mileage/bank chips, and the Save button.
struct ReviewStep: View {
    @Environment(\.accent) private var accent
    @Binding var draft: ExtractedReceipt
    // Presentation-only in v1: re-skins the toggle live but is NOT the save target.
    // `CaptureViewModel.save()` always persists under `profiles.activeProfile` (the
    // txn `mode`/`profileId` come from the active profile, per the scope-by-active-
    // profileId rule). See the toggle comment below.
    @Binding var mode: String                 // "personal" | "business"
    let onSave: () -> Void

    private var categoryKeys: [String] { CategoryKey.allCases.map(\.rawValue) }
    private func label(_ key: String) -> String {
        guard let ck = CategoryKey(rawValue: key) else { return key.capitalized }
        return CATS[ck]?.label ?? key.capitalized
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                totalCard
                aiBanner
                fieldsCard
                lineItemsCard
                disabledChips
                saveButton
            }
            .padding(18)
        }
        .background(Palette.cream)
    }

    private var totalCard: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Total detected").font(.ui(13)).foregroundStyle(Palette.ink2)
                Spacer()
                if let gst = draft.gst {
                    Text("GST \(amount(gst))")
                        .font(.ui(11.5, .semibold)).foregroundStyle(accent.deep)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(accent.soft, in: Capsule())
                }
            }
            Text(amount(draft.total)).numeric(40)
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .cardShadow()
    }

    @ViewBuilder
    private var aiBanner: some View {
        let text = draft.needsReview
            ? "Double-check the details below."
            : bannerTemplate
        HStack(alignment: .top, spacing: 10) {
            Icon(name: "sparkles", size: 18, color: accent.base)
            Text(text).font(.ui(13)).foregroundStyle(Palette.ink)
            Spacer()
            if !draft.needsReview {
                Text("\(draft.confidenceBadge)%")
                    .font(.ui(12, .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(accent.base, in: Capsule())
                    .accessibilityIdentifier(AccessibilityID.captureReviewBadge)
            }
        }
        .padding(14)
        .background(accent.soft, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                .stroke(accent.base.opacity(0.35), lineWidth: 1)
        )
    }

    private var bannerTemplate: String {
        var s = "Looks like a \(draft.merchant) — filed under \(label(draft.categoryKey))"
        if let d = draft.deductible { s += ", claimable at \(d)%" }
        return s + "."
    }

    private var fieldsCard: some View {
        VStack(spacing: 12) {
            field("Merchant") {
                TextField("Merchant", text: $draft.merchant)
                    .accessibilityIdentifier(AccessibilityID.captureReviewMerchant)
            }
            field("Date") { TextField("YYYY-MM-DD", text: $draft.date) }
            field("Category") {
                Picker("Category", selection: $draft.categoryKey) {
                    ForEach(categoryKeys, id: \.self) { Text(label($0)).tag($0) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier(AccessibilityID.captureReviewCategory)
            }
            field("Payment") {
                TextField("Payment method", text: Binding(
                    get: { draft.paymentMethod ?? "" },
                    set: { draft.paymentMethod = $0.isEmpty ? nil : $0 }))
            }
            field("Tax label") {
                TextField("e.g. GST", text: Binding(
                    get: { draft.taxLabel ?? "" },
                    set: { draft.taxLabel = $0.isEmpty ? nil : $0 }))
            }
            profileToggle
        }
        .padding(16)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .cardShadow()
    }

    // v1: presentation-only. Toggling Personal/Business re-skins the card live but
    // does NOT change which profile the txn is saved under — `save()` uses
    // `profiles.activeProfile` (scope-by-active-profileId). This is intentional for
    // v1; switching the save target is deferred.
    private var profileToggle: some View {
        HStack(spacing: 8) {
            ForEach(ProfileType.allCases) { type in
                let selected = mode == type.rawValue
                Button { mode = type.rawValue } label: {
                    Text(type.label)
                        .font(.ui(13, .semibold))
                        .foregroundStyle(selected ? .white : Palette.ink2)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(selected ? accent.base : Palette.paper2,
                                    in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityIdentifier(AccessibilityID.captureReviewProfileToggle)
    }

    private var lineItemsCard: some View {
        Group {
            if !draft.lineItems.isEmpty {
                VStack(spacing: 8) {
                    ForEach(Array(draft.lineItems.enumerated()), id: \.offset) { _, li in
                        HStack {
                            Text(li.name).font(.ui(13)).foregroundStyle(Palette.ink)
                            Spacer()
                            Text(amount(li.price)).font(.ui(13, .semibold)).foregroundStyle(Palette.ink2)
                        }
                    }
                }
                .padding(16)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .cardShadow()
            }
        }
    }

    private var disabledChips: some View {
        HStack(spacing: 8) {
            chip("Add to mileage", icon: "plus")
            chip("Match to bank", icon: "wallet")
        }
        .opacity(0.45)
    }

    private func chip(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Icon(name: icon, size: 14, color: Palette.ink2)
            Text(title).font(.ui(12, .semibold)).foregroundStyle(Palette.ink2)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Palette.paper2, in: Capsule())
    }

    private var saveButton: some View {
        Button(action: onSave) {
            Text("Save receipt")
                .font(.ui(16, .bold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(accent.base, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.captureSave)
    }

    @ViewBuilder
    private func field(_ title: String, @ViewBuilder _ control: () -> some View) -> some View {
        HStack {
            Text(title).font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
                .frame(width: 92, alignment: .leading)
            control().font(.ui(15)).foregroundStyle(Palette.ink)
        }
    }

    /// Display a dollar Decimal as "$X.XX".
    private func amount(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "AUD"
        f.locale = Locale(identifier: "en_AU")
        return f.string(from: d as NSDecimalNumber) ?? "$0.00"
    }
}
