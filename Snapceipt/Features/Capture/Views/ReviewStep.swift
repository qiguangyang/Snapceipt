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
    /// Dismisses the whole capture overlay (the only cancel affordance on Review).
    let onClose: () -> Void

    private var categoryKeys: [String] { CategoryKey.allCases.map(\.rawValue) }
    private func label(_ key: String) -> String {
        guard let ck = CategoryKey(rawValue: key) else { return key.capitalized }
        return CATS[ck]?.label ?? key.capitalized
    }

    var body: some View {
        VStack(spacing: 0) {
            header
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
            // Right-aligned "hide keyboard" accessory for the editable fields above.
            .keyboardDismissButton()
        }
        .background(Palette.cream)
    }

    /// Top bar: a close button (the only cancel affordance on Review) + the
    /// "Review receipt" title (spec §2 L142-145). The prototype's decorative,
    /// no-handler edit button is intentionally omitted (no `edit` icon, no action).
    private var header: some View {
        ZStack {
            Text("Review receipt")
                .font(.ui(17, .bold)).foregroundStyle(Palette.ink)
            HStack {
                CaptureCloseButton(onClose: onClose)
                Spacer()
            }
        }
        .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 12)
    }

    private var totalCard: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Total detected").font(.ui(13)).foregroundStyle(Palette.ink2)
                Spacer()
                if let gst = draft.gst {
                    // The GST/income pill is pinned to income-green in BOTH profile
                    // modes (spec §2 L123) — it is NOT accent-driven.
                    HStack(spacing: 5) {
                        Icon(name: "check", size: 12, color: Palette.income)
                        Text("incl. \(fmt(gst)) GST")
                    }
                    .font(.ui(11.5, .semibold)).foregroundStyle(Palette.income)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Palette.incomeSoft, in: Capsule())
                }
            }
            Text(fmt(draft.total)).numeric(40)
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .cardShadow()
    }

    @ViewBuilder
    private var aiBanner: some View {
        let body = draft.needsReview
            ? "Double-check the details below."
            : bannerTemplate
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Icon(name: "sparkles", size: 18, color: accent.base)
                Text(draft.needsReview ? "Review needed" : "AI categorised this for you")
                    .font(.ui(13.5, .bold)).foregroundStyle(accent.deep)
                Spacer()
                if !draft.needsReview {
                    Text("\(draft.confidenceBadge)% match")
                        .font(.ui(11, .bold)).foregroundStyle(accent.deep)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Palette.paper, in: Capsule())
                        .accessibilityIdentifier(AccessibilityID.captureReviewBadge)
                }
            }
            Text(body).font(.ui(13)).foregroundStyle(Palette.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(AccessibilityID.captureReviewBanner)
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
                .tint(accent.base)   // active accent, not the iOS system-blue menu tint
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
            if mode == "business" {
                Toggle("GST-free (no GST)", isOn: Binding(
                    get: { draft.gstFree },
                    set: { isFree in
                        draft.gstFree = isFree
                        // Authority rule: keep the displayed GST in sync immediately.
                        let r = GstTreatment.applyGstFree(isFree, totalCents: Int((draft.total as NSDecimalNumber).doubleValue * 100))
                        draft.gst = r.gstCents.map { Decimal($0) / 100 }
                    }))
                    .accessibilityIdentifier(AccessibilityID.txnGstFreeToggle)

                Toggle("Capital purchase (asset)", isOn: $draft.capital)
                    .accessibilityIdentifier(AccessibilityID.txnCapitalToggle)

                if !draft.gstFree {
                    field("GST amount") {
                        TextField("GST", text: Binding(
                            get: { draft.gst.map { "\($0)" } ?? "" },
                            set: { s in
                                let cents = Int((Double(s) ?? 0) * 100)
                                let r = GstTreatment.applyManualGst(cents)
                                draft.gst = r.gstCents.map { Decimal($0) / 100 }
                            }))
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier(AccessibilityID.txnGstAmountField)
                    }
                }
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Assign to profile")
                .font(.ui(13, .bold)).foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            segmented
        }
        .accessibilityIdentifier(AccessibilityID.captureReviewProfileToggle)
    }

    /// The default ModeToggle Segmented sliding control (spec §2 L152-155): a paper-2
    /// track with a single white thumb that animates between Personal/Business, each
    /// option carrying a leading icon tinted to its FIXED per-option color (Personal
    /// wallet+terracotta, Business building+teal) when selected, else --ink-3.
    private var segmented: some View {
        let types = ProfileType.allCases
        let selectedIndex = types.firstIndex { mode == $0.rawValue } ?? 0
        return GeometryReader { geo in
            let thumbW = (geo.size.width - 8) / CGFloat(types.count)
            ZStack(alignment: .leading) {
                // Sliding white thumb with a soft shadow.
                Capsule()
                    .fill(Palette.paper)
                    .shadow(color: Palette.ink.opacity(0.18), radius: 3, x: 0, y: 2)
                    .frame(width: thumbW)
                    .padding(.vertical, 4)
                    .offset(x: 4 + CGFloat(selectedIndex) * thumbW)
                    .animation(.spring(response: 0.28, dampingFraction: 0.82), value: selectedIndex)

                HStack(spacing: 0) {
                    ForEach(types) { type in
                        let selected = mode == type.rawValue
                        Button { mode = type.rawValue } label: {
                            HStack(spacing: 6) {
                                Icon(name: type.iconName, size: 16,
                                     color: selected ? optionTint(type) : Palette.ink3)
                                Text(type.label)
                                    .font(.ui(14, .semibold))
                                    .foregroundStyle(selected ? Palette.ink : Palette.ink3)
                            }
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(height: 46)
        .background(Palette.paper2, in: Capsule())
    }

    /// FIXED per-option tint (spec §2 L155): Personal terracotta, Business teal,
    /// independent of the active accent.
    private func optionTint(_ type: ProfileType) -> Color {
        type == .personal ? AccentPalette.personal.base : AccentPalette.business.base
    }

    private var lineItemsCard: some View {
        Group {
            if !draft.lineItems.isEmpty {
                VStack(spacing: 8) {
                    ForEach(Array(draft.lineItems.enumerated()), id: \.offset) { _, li in
                        HStack {
                            Text(li.name).font(.ui(13)).foregroundStyle(Palette.ink)
                            Spacer()
                            Text(fmt(li.price)).font(.ui(13, .semibold)).foregroundStyle(Palette.ink2)
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
            HStack(spacing: 8) {
                Icon(name: "check", size: 20, color: .white)
                Text("Save receipt").font(.ui(16, .bold)).foregroundStyle(.white)
            }
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
}
