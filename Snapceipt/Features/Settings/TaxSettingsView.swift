import SwiftUI
import SwiftData
import PhotosUI

/// Tax & GST editor (F7). Bound to `TaxSettingsViewModel` over the active profile's
/// `tax_settings` row (+ the Profile's ABN/GST identity). Mirrors the shared sub-page
/// chrome: cream background, `SheetHeader`, a `ScrollView` of grouped `Card`s preceded
/// by two stat-pill cards (Deductible YTD / GST on purchases, derived in-view from the
/// active profile's `Transaction` rows). Business identity is gated on
/// `vm.showsBusinessIdentity` (Personal profiles hide it). Financial-year group shows
/// the derived next-BAS-due; a paper-2 info note closes the deduction-defaults group.
struct TaxSettingsView: View {
    let profiles: ProfilesStore
    let sync: any SyncEnqueuing
    let api: APIClient
    let onClose: () -> Void

    @Environment(\.accent) private var accent
    @State private var vm: TaxSettingsViewModel?

    // Local edit mirrors for the text fields (committed to the VM on change).
    @State private var abnText = ""
    @State private var wfhText = ""
    @State private var businessEmailText = ""
    @State private var phoneText = ""
    @State private var websiteText = ""
    @State private var addressTextField = ""
    @State private var bankDetailsText = ""
    @State private var logoItem: PhotosPickerItem?
    /// Tracks the focused text field so each commits to the VM when focus LEAVES it (on-blur)
    /// rather than on every keystroke (which re-renders the field mid-typing). A "Save" button
    /// commits everything explicitly with a confirmation toast.
    @FocusState private var focusedField: TaxField?
    private enum TaxField: Hashable { case abn, wfh, businessEmail, phone, website, address, bankDetails }
    @Environment(ToastCenter.self) private var toasts

    /// Pin the calendar's locale to en-AU so `monthSymbols` resolves to full English
    /// month names ("July"), not the generic ISO placeholders ("M07") the runtime
    /// locale (e.g. en_US@rg=auzzzz) yields — matching the app-wide en-AU house style
    /// (`Formatters.swift`, `Period.swift`).
    private static let auLocale = Locale(identifier: "en_AU")
    private static let monthNames: [String] = {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = auLocale
        return cal.monthSymbols
    }()
    private let entityTypes = ["Sole trader", "Company", "Partnership", "Trust"]
    private let gstBases = ["Cash", "Accruals"]

    var body: some View {
        ZStack {
            Palette.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                SheetHeader(title: "Tax & GST settings",
                            onClose: { if let vm { commitAll(vm) }; onClose() },
                            trailing: AnyView(headerSaveButton))
                if let vm {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            statPills(vm)
                            if vm.showsBusinessIdentity {
                                businessIdentity(vm)
                                businessDetails(vm)
                                bankDetails(vm)
                            }
                            financialYear(vm)
                            deductionDefaults(vm)
                        }
                        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 60)
                    }
                    .keyboardDismissButton() // dismiss button for ABN + WFH-rate fields
                    .onChange(of: focusedField) { _, _ in
                        commitAll(vm)   // any focus change (field→field, or →nil on keyboard dismiss) saves ALL
                    }
                } else { Color.clear }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.taxScreen)
        .transition(.opacity)
        .task {
            if vm == nil, let profile = profiles.profiles.first(where: { $0.id == profiles.activeProfileId }) {
                let model = TaxSettingsViewModel(context: profiles.context, sync: sync,
                                                 userId: profiles.userId, profile: profile, api: api)
                abnText = model.abn
                wfhText = String(model.wfhRateCentsPerHour)
                businessEmailText = model.businessEmail
                phoneText = model.phone
                websiteText = model.website
                addressTextField = model.addressText
                bankDetailsText = model.bankDetails
                vm = model
            }
        }
        .onDisappear { if let vm { commitAll(vm) } }   // swipe-to-dismiss never calls onClose — save here
    }

    // MARK: - Stat pills (Deductible YTD / GST on purchases)

    @ViewBuilder private func statPills(_ vm: TaxSettingsViewModel) -> some View {
        let s = computeTaxStats(startMonth: vm.financialYearStartMonth)
        HStack(spacing: 12) {
            statPill(icon: "shield", tint: Palette.income, soft: Palette.incomeSoft,
                     value: fmt(s.deductibleCents, showCents: false), caption: "Deductible YTD")
            statPill(icon: "receipt", tint: accent.base, soft: accent.soft,
                     value: fmt(s.gstCents, showCents: false), caption: "GST on purchases")
        }
    }

    private func statPill(icon: String, tint: Color, soft: Color, value: String, caption: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                IconCircle(name: icon, tint: tint, soft: soft, size: 38, iconSize: 19)
                VStack(alignment: .leading, spacing: 2) {
                    Text(value).numeric(20).foregroundStyle(Palette.ink)
                    Text(caption).font(.ui(12, .regular)).foregroundStyle(Palette.ink3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Year-to-date totals from non-deleted `Transaction` rows scoped to the active
    /// profile and the current financial year: deductible amount (expense magnitude ×
    /// deductiblePct, default 100% when nil) and recoverable GST on purchases.
    private func computeTaxStats(startMonth: Int) -> (deductibleCents: Int, gstCents: Int) {
        let pid = profiles.activeProfileId
        let fy = FinancialYear.of(Date(), startMonth: startMonth).startYear
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil }
        )
        let txns = (try? profiles.context.fetch(descriptor)) ?? []
        var deductible = 0
        var gst = 0
        for t in txns where t.amountCents < 0 && FinancialYear.isIn(t.txnDate, fyStartYear: fy, startMonth: startMonth) {
            let mag = -t.amountCents
            let pct = t.deductiblePct ?? 100
            deductible += Int((Double(mag) * Double(pct) / 100.0).rounded())
            gst += t.gstCents ?? 0
        }
        return (deductible, gst)
    }

    // MARK: - Business identity (Business profiles only)

    @ViewBuilder private func businessIdentity(_ vm: TaxSettingsViewModel) -> some View {
        groupLabel("Business")
        Card {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ABN").font(.ui(11.5, .bold)).tracking(0.4).foregroundStyle(Palette.ink3)
                    TextField("00 000 000 000", text: $abnText)
                        .font(.ui(16, .regular))
                        .padding(12).background(Palette.paper2, in: RoundedRectangle(cornerRadius: 12))
                        .focused($focusedField, equals: .abn)
                        .accessibilityIdentifier(AccessibilityID.taxAbnField)
                    if ABNValidator.looksInvalid(abnText) {
                        Text("This ABN doesn't look right — check the digits.")
                            .font(.ui(12)).foregroundStyle(Palette.alert)
                            .accessibilityIdentifier(AccessibilityID.taxAbnHint)
                    }
                }
                divider
                menuRow(title: "Entity type", value: vm.entityType, options: entityTypes) { vm.entityType = $0 }
                divider
                Toggle("Registered for GST", isOn: Binding(
                    get: { vm.gstRegistered },
                    set: { vm.setGstRegistered($0) }))
                    .toggleStyle(MiniSwitchToggleStyle())
                    .font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink2)
                    .accessibilityIdentifier(AccessibilityID.taxGstToggle)
                divider
                VStack(alignment: .leading, spacing: 8) {
                    Text("Business currency").font(.ui(11.5, .bold)).tracking(0.4).foregroundStyle(Palette.ink3)
                    Picker("Business currency", selection: Binding(
                        get: { vm.businessCurrency },
                        set: { vm.businessCurrency = $0 })) {
                            ForEach(AppSettings.businessCurrencies, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.segmented)
                }
                divider
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(receiptTaxLabel(for: vm.businessCurrency)) rate").font(.ui(11.5, .bold)).tracking(0.4).foregroundStyle(Palette.ink3)
                    Picker("GST rate", selection: Binding(
                        get: { vm.gstRatePreset },
                        set: { vm.setGstRatePreset($0) })) {
                            ForEach(GstRatePreset.allCases) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier(AccessibilityID.taxGstRateControl)
                    if vm.gstRatePreset == .custom {
                        HStack(spacing: 6) {
                            TextField("12.5", text: Binding(
                                get: { vm.gstRatePercentText },
                                set: { if let pct = Double($0) { vm.setCustomGstPercent(pct) } }))
                                .keyboardType(.decimalPad)
                                .font(.ui(16, .regular))
                                .padding(12).background(Palette.paper2, in: RoundedRectangle(cornerRadius: 12))
                                .accessibilityIdentifier(AccessibilityID.taxGstRateCustom)
                            Text("%").font(.ui(16)).foregroundStyle(Palette.ink2)
                        }
                    }
                }
                divider
                menuRow(title: "GST accounting", value: vm.gstBasis, options: gstBases) { vm.gstBasis = $0 }
            }
        }
    }

    // MARK: - Business details + Bank details (Business profiles only)

    @ViewBuilder private func businessDetails(_ vm: TaxSettingsViewModel) -> some View {
        groupLabel("Business details")
        Card {
            VStack(alignment: .leading, spacing: 14) {
                labeledField("Business email", placeholder: "you@business.com",
                             text: $businessEmailText, id: AccessibilityID.taxBusinessEmailField,
                             keyboard: .emailAddress, field: .businessEmail)
                divider
                labeledField("Phone", placeholder: "0400 000 000",
                             text: $phoneText, id: AccessibilityID.taxBusinessPhoneField,
                             keyboard: .phonePad, field: .phone)
                divider
                labeledField("Website", placeholder: "yourbusiness.com",
                             text: $websiteText, id: AccessibilityID.taxBusinessWebsiteField,
                             keyboard: .URL, field: .website)
                divider
                VStack(alignment: .leading, spacing: 6) {
                    Text("Address").font(.ui(11.5, .bold)).tracking(0.4).foregroundStyle(Palette.ink3)
                    TextField("Street, suburb, state", text: $addressTextField, axis: .vertical)
                        .lineLimit(2...4)
                        .font(.ui(16, .regular))
                        .padding(12).background(Palette.paper2, in: RoundedRectangle(cornerRadius: 12))
                        .focused($focusedField, equals: .address)
                        .accessibilityIdentifier(AccessibilityID.taxBusinessAddressField)
                }
                divider
                logoRow(vm)
            }
        }
    }

    @ViewBuilder private func logoRow(_ vm: TaxSettingsViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Logo").font(.ui(11.5, .bold)).tracking(0.4).foregroundStyle(Palette.ink3)
            HStack(spacing: 12) {
                if vm.isUploadingLogo {
                    ProgressView().frame(width: 48, height: 48)
                } else if let logo = vm.logoImage {
                    Image(uiImage: logo).resizable().scaledToFill()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line, lineWidth: 1))
                        .accessibilityIdentifier(AccessibilityID.taxBusinessLogoPreview)
                } else if vm.logoR2Key != nil {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 28))
                        .foregroundStyle(accent.base).frame(width: 48, height: 48)
                        .accessibilityIdentifier(AccessibilityID.taxBusinessLogoPreview)
                } else {
                    Image(systemName: "photo").font(.system(size: 24)).foregroundStyle(Palette.ink3)
                        .frame(width: 48, height: 48)
                        .background(Palette.paper2, in: RoundedRectangle(cornerRadius: 12))
                }
                PhotosPicker(selection: $logoItem, matching: .images) {
                    Text(vm.logoR2Key == nil ? "Add logo" : "Change logo")
                        .font(.ui(14.5, .semibold)).foregroundStyle(accent.base)
                }
                .disabled(vm.isUploadingLogo)
                .accessibilityIdentifier(AccessibilityID.taxBusinessLogoPicker)
            }
            if let err = vm.logoUploadError {
                Text(err).font(.ui(12)).foregroundStyle(Palette.alert)
            }
        }
        .onChange(of: logoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    await vm.uploadLogo(image)
                }
                logoItem = nil
            }
        }
    }

    @ViewBuilder private func bankDetails(_ vm: TaxSettingsViewModel) -> some View {
        groupLabel("Bank details")
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text("Payment details").font(.ui(11.5, .bold)).tracking(0.4).foregroundStyle(Palette.ink3)
                TextField("BSB + account, PayID, or international details", text: $bankDetailsText, axis: .vertical)
                    .lineLimit(3...6)
                    .font(.ui(16, .regular))
                    .padding(12).background(Palette.paper2, in: RoundedRectangle(cornerRadius: 12))
                    .focused($focusedField, equals: .bankDetails)
                    .accessibilityIdentifier(AccessibilityID.taxBankDetailsField)
            }
        }
    }

    /// A label + single-line text field that commits to the VM on change (mirrors the ABN row).
    @ViewBuilder private func labeledField(_ title: String, placeholder: String,
                                           text: Binding<String>, id: String,
                                           keyboard: UIKeyboardType,
                                           field: TaxField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.ui(11.5, .bold)).tracking(0.4).foregroundStyle(Palette.ink3)
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()  // these fields aren't prose
                .font(.ui(16, .regular))
                .padding(12).background(Palette.paper2, in: RoundedRectangle(cornerRadius: 12))
                .focused($focusedField, equals: field)  // commits on blur (see onChange(focusedField))
                .accessibilityIdentifier(id)
        }
    }

    /// Commit a single text field's @State mirror to the VM (called when it loses focus).
    private func commitField(_ field: TaxField, _ vm: TaxSettingsViewModel) {
        switch field {
        case .abn: vm.setAbn(abnText)
        case .wfh: vm.setWfhRate(Int(wfhText) ?? 0)
        case .businessEmail: vm.setBusinessEmail(businessEmailText)
        case .phone: vm.setPhone(phoneText)
        case .website: vm.setWebsite(websiteText)
        case .address: vm.setAddressText(addressTextField)
        case .bankDetails: vm.setBankDetails(bankDetailsText)
        }
    }

    /// Commit every text field — the explicit Save button + on-close, so nothing is lost.
    private func commitAll(_ vm: TaxSettingsViewModel) {
        for f in [TaxField.abn, .wfh, .businessEmail, .phone, .website, .address, .bankDetails] {
            commitField(f, vm)
        }
    }

    /// Top-right Save: accent when there are unsaved edits, grayed + disabled when everything is
    /// already saved. (Fields also auto-save on blur/close; this is the explicit commit + the
    /// saved/unsaved indicator the design asked for.)
    @ViewBuilder private var headerSaveButton: some View {
        if let vm {
            let dirty = hasUnsavedChanges(vm)
            Button {
                focusedField = nil      // blur (commits the active field) then save all
                commitAll(vm)
                toasts.show("Saved", kind: .success)
            } label: {
                Text("Save").font(.ui(15, .bold))
                    .foregroundStyle(dirty ? accent.base : Palette.ink3)
            }
            .buttonStyle(.plain)
            .disabled(!dirty)
            .accessibilityIdentifier(AccessibilityID.taxSave)
        } else {
            Color.clear.frame(width: 40, height: 40)
        }
    }

    /// True when any text field's local edit differs from the value committed to the VM.
    private func hasUnsavedChanges(_ vm: TaxSettingsViewModel) -> Bool {
        abnText != vm.abn
        || businessEmailText != vm.businessEmail
        || phoneText != vm.phone
        || websiteText != vm.website
        || addressTextField != vm.addressText
        || bankDetailsText != vm.bankDetails
        || wfhText != String(vm.wfhRateCentsPerHour)
    }

    // MARK: - Financial year

    @ViewBuilder private func financialYear(_ vm: TaxSettingsViewModel) -> some View {
        groupLabel("Financial year")
        Card {
            VStack(alignment: .leading, spacing: 14) {
                monthMenuRow(vm)
                divider
                menuRow(title: "BAS period", value: vm.basPeriod.label, options: BasPeriod.allCases.map(\.label)) { label in
                    if let p = BasPeriod.allCases.first(where: { $0.label == label }) { vm.basPeriodRaw = p.rawValue }
                }
                divider
                HStack {
                    Text("Next BAS due").font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink2)
                    Spacer()
                    Text(fmtBasDue(vm.nextBasDue))
                        .font(.ui(14.5, .bold)).foregroundStyle(accent.base)
                }
            }
        }
    }

    @ViewBuilder private func monthMenuRow(_ vm: TaxSettingsViewModel) -> some View {
        let names = Self.monthNames
        HStack {
            Text("Tax year start").font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink2)
            Spacer()
            Picker("Tax year start", selection: Binding(
                get: { vm.financialYearStartMonth },
                set: { vm.setFinancialYearStartMonth($0) })) {
                    ForEach(1...12, id: \.self) { m in Text(names[m - 1]).tag(m) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(Palette.ink)
                .accessibilityIdentifier(AccessibilityID.taxFyStart)
        }
    }

    // MARK: - Deduction defaults

    @ViewBuilder private func deductionDefaults(_ vm: TaxSettingsViewModel) -> some View {
        groupLabel("Deduction defaults")
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Meals deductible").font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink2)
                    Spacer()
                    Text("\(vm.mealsDeductiblePct)%").font(.ui(14.5, .bold)).foregroundStyle(accent.base)
                    Stepper("", value: Binding(
                        get: { vm.mealsDeductiblePct },
                        set: { vm.setMealsDeductiblePct($0) }), in: 0...100, step: 5)
                        .labelsHidden()
                        .accessibilityIdentifier(AccessibilityID.taxMealsPct)
                }
                divider
                VStack(alignment: .leading, spacing: 6) {
                    Text("HOME OFFICE (C/HR)").font(.ui(11.5, .bold)).tracking(0.4).foregroundStyle(Palette.ink3)
                    TextField("70", text: $wfhText).keyboardType(.numberPad)
                        .font(.ui(16, .regular))
                        .padding(12).background(Palette.paper2, in: RoundedRectangle(cornerRadius: 12))
                        .focused($focusedField, equals: .wfh)
                }
                divider
                HStack {
                    Text("Vehicle").font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink2)
                    Spacer()
                    Text("88c / km").font(.ui(14.5, .bold)).foregroundStyle(Palette.ink)
                }
            }
        }
        infoNote("These defaults pre-fill the deductible % and rates when you file a new receipt. You can still override them per receipt.")
    }

    // MARK: - Helpers

    private var divider: some View {
        Rectangle().fill(Palette.line2).frame(height: 1)
    }

    private func infoNote(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Icon(name: "info", size: 18, color: Palette.ink3).padding(.top, 1)
            Text(text).font(.ui(12.5)).foregroundStyle(Palette.ink2).lineSpacing(2)
        }
        .padding(14)
        .background(Palette.paper2, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
    }

    private func groupLabel(_ s: String) -> some View {
        Text(s.uppercased()).font(.ui(12.5, .bold)).tracking(0.3).foregroundStyle(Palette.ink3)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
    }

    /// A native iOS pull-down selector: the row stays put (showing the value + chevron)
    /// and tapping pops a system menu with a checkmark on the current choice. Replaces the
    /// custom-label `Menu` whose label blanked out while the popup was open.
    private func menuRow(title: String, value: String, options: [String], onSelect: @escaping (String) -> Void) -> some View {
        HStack {
            Text(title).font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink2)
            Spacer()
            Picker(title, selection: Binding(get: { value }, set: { onSelect($0) })) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(Palette.ink)
        }
    }
}

/// The design's "MiniSwitch": a 46×28 pill whose ON track is `Palette.income`, with a
/// 22px white knob that slides 3 → 21. Implemented as a `ToggleStyle` over a real
/// `Toggle` so it still surfaces to accessibility as a switch element (XCUI queries the
/// GST toggle via `app.switches[...]`) while rendering the design's pill. The wrapped
/// `Toggle`'s label sits at the leading edge; the switch trails after a `Spacer`.
/// Shared by `TaxSettingsView` + `ProfileDetailView`.
struct MiniSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 8)
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(configuration.isOn ? Palette.income : Palette.line)
                    .frame(width: 46, height: 28)
                Circle()
                    .fill(Palette.paper)
                    .frame(width: 22, height: 22)
                    .padding(.horizontal, 3)
                    .shadow(color: Palette.ink.opacity(0.18), radius: 1.5, x: 0, y: 1)
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isOn)
            .contentShape(Rectangle())
            .onTapGesture { configuration.isOn.toggle() }
        }
    }
}
