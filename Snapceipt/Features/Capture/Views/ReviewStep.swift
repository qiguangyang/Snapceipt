import SwiftUI

/// Focus target for the editable Review line-item rows.
private enum ReviewItemField: Hashable { case name(String), price(String) }

/// The designed editable review card: total + GST pill, the AI-suggestion banner,
/// the confidence badge (shown iff !needsReview), editable merchant/date/category/
/// payment/tax-label, a Personal/Business profile toggle that re-skins live, a
/// read-only line-items list, disabled mileage/bank chips, and the Save button.
struct ReviewStep: View {
    @Environment(\.accent) private var accent
    @Environment(EntitlementStore.self) private var entitlement
    @Binding var draft: ExtractedReceipt
    /// The profile the receipt will be saved under (Review "Assign to profile"). Drives
    /// the business-only GST fields via `selectedType`; passed to `save(toProfileId:)`.
    @Binding var selectedProfileId: String
    /// The view model, read-only here — ReviewStep only reads `smartScanCapped` /
    /// `smartScanCap`; it never mutates the VM directly.
    let vm: CaptureViewModel
    let onSave: () -> Void
    /// Dismisses the whole capture overlay (the only cancel affordance on Review).
    let onClose: () -> Void

    @State private var showPaywall = false
    /// Editable line-item rows (name + price-as-text), seeded from `draft.lineItems`
    /// and synced back on every edit so `save()` persists the user's changes.
    @State private var itemDrafts: [ItemDraft] = []
    @FocusState private var focusedItem: ReviewItemField?
    /// Editable total buffer (a string so decimal typing isn't reformatted mid-entry).
    @State private var totalText = ""
    /// Gates item→total auto-recompute until after the initial seed, so loading the
    /// extracted draft doesn't overwrite the AI's detected total with the items sum.
    @State private var didSeed = false

    private var categoryKeys: [String] { CategoryKey.allCases.map(\.rawValue) }
    private func label(_ key: String) -> String {
        guard let ck = CategoryKey(rawValue: key) else { return key.capitalized }
        return CATS[ck]?.label ?? key.capitalized
    }

    /// The selected profile's type — drives the business-only GST fields and the icon.
    private var selectedType: String {
        vm.profileOptions.first(where: { $0.id == selectedProfileId })?.type
            ?? ProfileType.personal.rawValue
    }
    private var selectedProfileName: String {
        vm.profileOptions.first(where: { $0.id == selectedProfileId })?.name ?? "Select profile"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 16) {
                    totalCard
                    // Upgrade nudge takes priority when capped + free; otherwise
                    // the standard AI banner (which may still say "Review needed").
                    if vm.smartScanCapped && !entitlement.isPro {
                        upgradeNudge
                    } else {
                        aiBanner
                    }
                    diagnosticLine
                    fieldsCard
                    // "Assign to profile" lives in its OWN block AFTER the details card.
                    profileBlock
                    lineItemsCard
                    disabledChips
                }
                // Leave room for the fixed bottom save bar.
                .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 120)
            }
            // Right-aligned "hide keyboard" accessory for the editable fields above.
            .keyboardDismissButton()
        }
        .background(Palette.cream)
        // Save button pinned to a fixed bottom bar over a cream scrim.
        .overlay(alignment: .bottom) { saveBar }
        .sheet(isPresented: $showPaywall) { PaywallView() }
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
            HStack(spacing: 2) {
                Text("$").numeric(40).foregroundStyle(Palette.ink)
                TextField("0.00", text: $totalText)
                    .numeric(40).foregroundStyle(Palette.ink)
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier(AccessibilityID.captureReviewTotal)
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .cardShadow()
        .onAppear {
            if totalText.isEmpty { totalText = Self.priceText(draft.total) }
        }
        // Editing the total directly updates the draft. (Editing line items below
        // re-drives the total; this stands until the next item edit.) GST is NOT derived
        // from the total — it's the receipt's value, edited in its own field below.
        .onChange(of: totalText) { _, _ in
            draft.total = Self.parseAmount(totalText)
        }
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
        .background(
            LinearGradient(colors: [accent.soft, Palette.paper],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                .stroke(accent.base.opacity(0.35), lineWidth: 1)
        )
    }

    /// Developer diagnostic line: which engine produced this draft + timing/confidence.
    /// Visible to all users by product decision; reads `vm.diagnostics`.
    @ViewBuilder
    private var diagnosticLine: some View {
        if let d = vm.diagnostics {
            Text(d.summary)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.ink3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .accessibilityIdentifier(AccessibilityID.captureReviewDiagnostics)
        }
    }

    /// Shown only when `vm.smartScanCapped && !entitlement.isPro`. Uses the free-plan
    /// cap (`vm.smartScanCap`, falling back to 10) as the user's allotment; the Pro
    /// upsell number (500) is always a literal — never derived from the free cap.
    @ViewBuilder
    private var upgradeNudge: some View {
        let freeCap = vm.smartScanCap ?? 10
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Icon(name: "sparkles", size: 18, color: accent.base)
                Text("Smart-scan limit reached")
                    .font(.ui(13.5, .bold)).foregroundStyle(accent.deep)
                Spacer()
            }
            Text("You've used all \(freeCap) free smart scans this month. Upgrade to Pro for 500/mo + BAS export, quotes & logbooks.")
                .font(.ui(13)).foregroundStyle(Palette.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(AccessibilityID.captureReviewUpgradeNudge)
            Button {
                showPaywall = true
            } label: {
                Text("Upgrade to Pro")
                    .font(.ui(13, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(accent.base, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.captureReviewUpgrade)
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
            if selectedType == "business" {
                Toggle("GST-free (no GST)", isOn: Binding(
                    get: { draft.gstFree },
                    set: { isFree in
                        draft.gstFree = isFree
                        // GST-free zeroes GST; turning it back on re-infers a starting
                        // value that's then editable in the GST field below.
                        let r = GstTreatment.applyGstFree(isFree, totalCents: Int((draft.total as NSDecimalNumber).doubleValue * 100))
                        draft.gst = r.gstCents.map { Decimal($0) / 100 }
                    }))
                    .accessibilityIdentifier(AccessibilityID.txnGstFreeToggle)

                Toggle("Capital purchase (asset)", isOn: $draft.capital)
                    .accessibilityIdentifier(AccessibilityID.txnCapitalToggle)
            }
            // GST is read from the receipt and editable here — NOT derived from the total
            // (some items can be GST-free, so total/11 is wrong). Hidden only when a
            // business receipt is marked GST-free.
            if !(selectedType == "business" && draft.gstFree) {
                field("GST") {
                    TextField("0.00", text: Binding(
                        get: { draft.gst.map { NSDecimalNumber(decimal: $0).stringValue } ?? "" },
                        set: { s in
                            let raw = s.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
                            draft.gst = raw.isEmpty ? nil : max(Decimal(string: raw) ?? 0, 0)
                        }))
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier(AccessibilityID.txnGstAmountField)
                }
            }
        }
        .padding(16)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .cardShadow()
    }

    /// "Assign to profile" + ModeToggle as its own card AFTER the details/fields card.
    private var profileBlock: some View {
        profileToggle
            .padding(16)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .cardShadow()
    }

    // The "Assign to profile" picker drives the real save target: the receipt is saved
    // under the selected profile via `CaptureViewModel.save(toProfileId:)`.
    private var profileToggle: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Assign to profile")
                .font(.ui(13, .bold)).foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            segmented
        }
        .accessibilityIdentifier(AccessibilityID.captureReviewProfileToggle)
    }

    /// Menu picker over ALL the user's profiles by name. Selecting one sets
    /// `selectedProfileId` (the save target) and drives the business-only GST fields.
    private var segmented: some View {
        Menu {
            ForEach(vm.profileOptions) { opt in
                Button { selectedProfileId = opt.id } label: {
                    if opt.id == selectedProfileId {
                        Label(opt.name, systemImage: "checkmark")
                    } else {
                        Text(opt.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Icon(name: selectedType == ProfileType.business.rawValue ? "building" : "wallet",
                     size: 16, color: accent.base)
                Text(selectedProfileName)
                    .font(.ui(14, .semibold)).foregroundStyle(Palette.ink)
                Spacer()
                Icon(name: "chevD", size: 15, color: Palette.ink3)
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .padding(.horizontal, 14)
            .background(Palette.paper2, in: Capsule())
        }
        .tint(accent.base)
    }

    /// Editable line items: name + price per row, with remove + add affordances
    /// (reuses the manual-entry row pattern). Edits sync straight into `draft.lineItems`.
    private var lineItemsCard: some View {
        VStack(spacing: 0) {
            ForEach($itemDrafts) { $item in
                itemRow($item)
            }
            addItemRow
        }
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .cardShadow()
        // Seed from the extracted draft once, then keep `draft.lineItems` in sync with
        // every edit so the saved receipt reflects the user's changes.
        .onAppear {
            if itemDrafts.isEmpty {
                itemDrafts = draft.lineItems.map {
                    ItemDraft(name: $0.name, priceText: Self.priceText($0.price))
                }
            }
            // Allow item→total recompute only after the seed settles (next runloop), so
            // the initial load doesn't clobber the AI's detected total with the items sum.
            DispatchQueue.main.async { didSeed = true }
        }
        .onChange(of: itemDrafts) { _, _ in
            syncItemsToDraft()
            // After the seed, editing line items automatically drives the total (which
            // in turn recomputes GST via the total's onChange).
            guard didSeed, !itemDrafts.isEmpty else { return }
            totalText = Self.priceText(Decimal(ManualItemsMapper.totalCents(itemDrafts)) / 100)
        }
    }

    private func itemRow(_ item: Binding<ItemDraft>) -> some View {
        let rowId = item.wrappedValue.id
        let index = itemDrafts.firstIndex { $0.id == rowId } ?? 0
        return VStack(spacing: 0) {
            if index > 0 {
                Rectangle().fill(Palette.line2).frame(height: 1).padding(.leading, 52)
            }
            HStack(spacing: 10) {
                Icon(name: "tag", size: 18, color: Palette.ink3).frame(width: 28)
                TextField("Item name", text: item.name)
                    .font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
                    .focused($focusedItem, equals: .name(rowId))
                    .accessibilityIdentifier("\(AccessibilityID.captureReviewItemNamePrefix)\(index)")
                Text("$").font(.ui(14, .semibold)).foregroundStyle(Palette.ink3)
                TextField("0.00", text: item.priceText)
                    .font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 66)
                    .focused($focusedItem, equals: .price(rowId))
                    .accessibilityIdentifier("\(AccessibilityID.captureReviewItemPricePrefix)\(index)")
                Button { itemDrafts.removeAll { $0.id == rowId } } label: {
                    Icon(name: "close", size: 13, color: Palette.ink3)
                        .frame(width: 26, height: 26)
                        .background(Palette.cream, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(AccessibilityID.captureReviewItemRemovePrefix)\(index)")
            }
            .padding(.vertical, 9).padding(.horizontal, 14)
        }
        .id("review-row-\(rowId)")
    }

    private var addItemRow: some View {
        Button {
            let newItem = ItemDraft()
            itemDrafts.append(newItem)
            // Focus the new row's name field once it renders, like manual entry.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focusedItem = .name(newItem.id)
            }
        } label: {
            HStack(spacing: 10) {
                Icon(name: "plus", size: 17, color: accent.base).frame(width: 28)
                Text(itemDrafts.isEmpty ? "Add item" : "Add another item")
                    .font(.ui(15, .semibold)).foregroundStyle(accent.base)
                Spacer()
            }
            .padding(.vertical, 14).padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.captureReviewItemsAdd)
    }

    /// Push the edited rows back into the draft (drop blank-name rows; clamp price ≥ 0).
    private func syncItemsToDraft() {
        draft.lineItems = itemDrafts.compactMap { d in
            let name = d.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let raw = d.priceText.replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespaces)
            let price = Decimal(string: raw) ?? 0
            return ExtractedReceipt.LineItemDraft(name: name, price: max(price, .zero))
        }
    }

    /// Format an extracted Decimal price for the editable text field ("" when zero).
    private static func priceText(_ price: Decimal) -> String {
        price == 0 ? "" : String(format: "%.2f", NSDecimalNumber(decimal: price).doubleValue)
    }

    /// Parse the editable total text → Decimal (≥ 0).
    private static func parseAmount(_ text: String) -> Decimal {
        let raw = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        return max(Decimal(string: raw) ?? 0, 0)
    }

    private var disabledChips: some View {
        HStack(spacing: 8) {
            chip("Add to mileage", icon: "car")
            chip("Match to bank", icon: "link")
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

    /// FIXED bottom bar: a clear→cream scrim behind the pinned Save button.
    private var saveBar: some View {
        VStack(spacing: 8) {
            // Surface a save failure (e.g. no active profile) instead of failing silently.
            if let error = vm.errorMessage {
                Text(error)
                    .font(.ui(13, .semibold)).foregroundStyle(Palette.alert)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier(AccessibilityID.captureSaveError)
            }
            Button(action: onSave) {
                HStack(spacing: 8) {
                    Icon(name: "check", size: 20, color: .white)
                    Text("Save receipt").font(.ui(16, .bold)).foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity).frame(height: 56)
                .background(accent.base, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: accent.base.opacity(0.4), radius: 12, x: 0, y: 10)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.captureSave)
        }
        .padding(.horizontal, 18)
        .padding(.top, 28)
        .padding(.bottom, 18)
        .background(
            LinearGradient(colors: [Palette.cream.opacity(0), Palette.cream],
                           startPoint: .top, endPoint: .bottom)
        )
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
