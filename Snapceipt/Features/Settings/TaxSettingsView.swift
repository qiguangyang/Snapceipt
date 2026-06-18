import SwiftUI
import SwiftData

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
    let onClose: () -> Void

    @Environment(\.accent) private var accent
    @State private var vm: TaxSettingsViewModel?

    // Local edit mirrors for the text fields (committed to the VM on change).
    @State private var abnText = ""
    @State private var wfhText = ""

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
                SheetHeader(title: "Tax & GST settings", onClose: onClose)
                if let vm {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            statPills(vm)
                            if vm.showsBusinessIdentity { businessIdentity(vm) }
                            financialYear(vm)
                            deductionDefaults(vm)
                        }
                        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 60)
                    }
                    .keyboardDismissButton() // dismiss button for ABN + WFH-rate fields
                } else { Color.clear }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.taxScreen)
        .transition(.opacity)
        .task {
            if vm == nil, let profile = profiles.profiles.first(where: { $0.id == profiles.activeProfileId }) {
                let model = TaxSettingsViewModel(context: profiles.context, sync: sync,
                                                 userId: profiles.userId, profile: profile)
                abnText = model.abn
                wfhText = String(model.wfhRateCentsPerHour)
                vm = model
            }
        }
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
                        .onChange(of: abnText) { _, v in vm.setAbn(v) }
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
                menuRow(title: "GST accounting", value: vm.gstBasis, options: gstBases) { vm.gstBasis = $0 }
            }
        }
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
        let label = "FY " + FinancialYear.of(Date(), startMonth: vm.financialYearStartMonth).label
            .replacingOccurrences(of: "FY", with: "")
        Menu {
            ForEach(1...12, id: \.self) { m in
                Button(names[m - 1]) { vm.setFinancialYearStartMonth(m) }
            }
        } label: {
            HStack {
                Text("Tax year").font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink2)
                Spacer()
                Text(label).font(.ui(14.5, .bold)).foregroundStyle(Palette.ink)
                Icon(name: "chevR", size: 16, color: Palette.ink3)
            }
        }
        .accessibilityIdentifier(AccessibilityID.taxFyStart)
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
                        .onChange(of: wfhText) { _, v in vm.setWfhRate(Int(v) ?? 0) }
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

    private func menuRow(title: String, value: String, options: [String], onSelect: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(options, id: \.self) { opt in Button(opt) { onSelect(opt) } }
        } label: {
            HStack {
                Text(title).font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink2)
                Spacer()
                Text(value).font(.ui(14.5, .bold)).foregroundStyle(Palette.ink)
                Icon(name: "chevR", size: 16, color: Palette.ink3)
            }
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
