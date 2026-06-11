import SwiftUI
import SwiftData

/// Tax & GST editor (F7). Bound to `TaxSettingsViewModel` over the active profile's
/// `tax_settings` row (+ the Profile's ABN/GST identity). Mirrors
/// `NotificationsSettingsView` chrome: cream background, `SheetHeader`, a `ScrollView`
/// of grouped `Card`s. Business identity is gated on `vm.showsBusinessIdentity`
/// (Personal profiles hide it). Financial-year group shows the derived next-BAS-due.
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
    /// en-AU "28 Jul 2026" (day-month-year, no comma) — the app's house date style
    /// (`Formatters.swift`), not the runtime locale's US "Jul 28, 2026".
    private static let basDueFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = auLocale
        f.dateFormat = "d MMM yyyy"
        return f
    }()
    private let entityTypes = ["Sole trader", "Company", "Partnership", "Trust"]
    private let gstBases = ["Cash", "Accruals"]

    var body: some View {
        ZStack {
            Palette.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                SheetHeader(title: "Tax & GST", onClose: onClose)
                if let vm {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if vm.showsBusinessIdentity { businessIdentity(vm) }
                            financialYear(vm)
                            deductionDefaults(vm)
                        }
                        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 60)
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
                                                 userId: profiles.userId, profile: profile)
                abnText = model.abn
                wfhText = String(model.wfhRateCentsPerHour)
                vm = model
            }
        }
    }

    // MARK: - Business identity (Business profiles only)

    @ViewBuilder private func businessIdentity(_ vm: TaxSettingsViewModel) -> some View {
        groupLabel("Business identity")
        Card {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ABN").font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
                    TextField("00 000 000 000", text: $abnText)
                        .padding(12).background(Palette.paper2, in: RoundedRectangle(cornerRadius: 12))
                        .onChange(of: abnText) { _, v in vm.setAbn(v) }
                        .accessibilityIdentifier(AccessibilityID.taxAbnField)
                }
                Toggle("Registered for GST", isOn: Binding(
                    get: { vm.gstRegistered },
                    set: { vm.setGstRegistered($0) }))
                    .font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                    .tint(accent.base)
                    .accessibilityIdentifier(AccessibilityID.taxGstToggle)
                menuRow(title: "Entity type", value: vm.entityType, options: entityTypes) { vm.entityType = $0 }
                menuRow(title: "GST accounting basis", value: vm.gstBasis, options: gstBases) { vm.gstBasis = $0 }
            }
        }
    }

    // MARK: - Financial year

    @ViewBuilder private func financialYear(_ vm: TaxSettingsViewModel) -> some View {
        groupLabel("Financial year")
        Card {
            VStack(alignment: .leading, spacing: 14) {
                monthMenuRow(vm)
                menuRow(title: "BAS period", value: vm.basPeriod.label, options: BasPeriod.allCases.map(\.label)) { label in
                    if let p = BasPeriod.allCases.first(where: { $0.label == label }) { vm.basPeriodRaw = p.rawValue }
                }
                HStack {
                    Text("Next BAS due").font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                    Spacer()
                    Text(Self.basDueFormatter.string(from: vm.nextBasDue))
                        .font(.ui(14.5, .semibold)).foregroundStyle(accent.base)
                }
            }
        }
    }

    @ViewBuilder private func monthMenuRow(_ vm: TaxSettingsViewModel) -> some View {
        let names = Self.monthNames
        Menu {
            ForEach(1...12, id: \.self) { m in
                Button(names[m - 1]) { vm.setFinancialYearStartMonth(m) }
            }
        } label: {
            HStack {
                Text("Tax year start month").font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                Spacer()
                Text(names[max(0, min(11, vm.financialYearStartMonth - 1))]).foregroundStyle(Palette.ink2)
                Icon(name: "chevD", size: 14, color: Palette.ink3)
            }
            .font(.ui(14.5))
        }
        .accessibilityIdentifier(AccessibilityID.taxFyStart)
    }

    // MARK: - Deduction defaults

    @ViewBuilder private func deductionDefaults(_ vm: TaxSettingsViewModel) -> some View {
        groupLabel("Deduction defaults")
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Meals deductible").font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                    Spacer()
                    Text("\(vm.mealsDeductiblePct)%").font(.ui(14.5, .semibold)).foregroundStyle(accent.base)
                    Stepper("", value: Binding(
                        get: { vm.mealsDeductiblePct },
                        set: { vm.setMealsDeductiblePct($0) }), in: 0...100, step: 5)
                        .labelsHidden()
                        .accessibilityIdentifier(AccessibilityID.taxMealsPct)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Home office (c/hr)").font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
                    TextField("70", text: $wfhText).keyboardType(.numberPad)
                        .padding(12).background(Palette.paper2, in: RoundedRectangle(cornerRadius: 12))
                        .onChange(of: wfhText) { _, v in vm.setWfhRate(Int(v) ?? 0) }
                }
                HStack {
                    Text("Vehicle (c/km)").font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                    Spacer()
                    Text("88c").font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink2)
                }
            }
        }
    }

    // MARK: - Helpers

    private func groupLabel(_ s: String) -> some View {
        Text(s).font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
    }

    private func menuRow(title: String, value: String, options: [String], onSelect: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(options, id: \.self) { opt in Button(opt) { onSelect(opt) } }
        } label: {
            HStack {
                Text(title).font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                Spacer()
                Text(value).foregroundStyle(Palette.ink2)
                Icon(name: "chevD", size: 14, color: Palette.ink3)
            }
            .font(.ui(14.5))
        }
    }
}
