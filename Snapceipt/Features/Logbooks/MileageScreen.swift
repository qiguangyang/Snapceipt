import SwiftUI
import SwiftData

/// Full-screen vehicle-logbook overlay (ATO logbook method). (§6.1)
struct MileageScreen: View {
    let context: ModelContext
    let sync: any SyncEnqueuing
    let userId: String
    let profileId: String
    let startMonth: Int
    let onClose: () -> Void

    @Environment(\.accent) private var accent
    @State private var vm: MileageViewModel?
    @State private var sheet: MileageSheet?

    private enum MileageSheet: Identifiable {
        case vehicle, logbook, trip, costs
        var id: Int { hashValue }
    }

    private var fyStartYear: Int { FinancialYear.of(Date(), startMonth: startMonth).startYear }

    var body: some View {
        ZStack(alignment: .bottom) {
            Palette.cream.ignoresSafeArea()
            if let vm {
                VStack(spacing: 0) {
                    LbHeader(title: "Vehicle logbook", onClose: onClose, onAdd: { sheet = .trip })
                    ScrollView {
                        VStack(spacing: 0) {
                            hero(vm)
                            vehicleCard(vm).padding(.top, 14)
                            logbookCard(vm).padding(.top, 14)
                            gpsCard.padding(.top, 14)
                            costsCard(vm).padding(.top, 14)
                            LbLabel(text: "Recent trips")
                            tripsList(vm)
                        }
                        .padding(.horizontal, 18).padding(.bottom, 110)
                    }
                }
                LbFloatingCTA(title: "Add a trip", a11yId: AccessibilityID.mileageAddTrip) { sheet = .trip }
            } else {
                Color.clear
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.mileageScreen)
        .transition(.opacity)
        .task {
            TaxSettingsSeeder.ensure(profileId: profileId, userId: userId, context: context, sync: sync)
            if vm == nil {
                vm = MileageViewModel(context: context, sync: sync, userId: userId,
                                      profileId: profileId, startMonth: startMonth)
            }
        }
        .sheet(item: $sheet) { which in sheetView(which) }
    }

    // MARK: cards

    @ViewBuilder private func hero(_ vm: MileageViewModel) -> some View {
        let h = vm.hero(fyStartYear: fyStartYear)
        let claim = vm.currentClaimCents(fyStartYear: fyStartYear)
        LbHero(icon: "car", label: "This financial year", pill: "Logbook method",
               bigNumber: String(format: "%.1f", h.businessKm), unit: "km",
               stats: [
                    ("Claimable", claim.map { fmt($0) } ?? "—"),
                    ("Business use", vm.vehicle?.businessUsePct.map { "\($0)%" } ?? "—"),
                    ("Trips", "\(h.tripCount)"),
               ])
    }

    @ViewBuilder private func vehicleCard(_ vm: MileageViewModel) -> some View {
        Button { sheet = .vehicle } label: {
            Card(padding: 14) {
                HStack(spacing: 12) {
                    IconCircle(name: "car", tint: accent.base, soft: accent.soft, size: 38, iconSize: 19)
                    VStack(alignment: .leading, spacing: 1) {
                        if let v = vm.vehicle, (v.make != nil || v.model != nil) {
                            Text([v.make, v.model].compactMap { $0 }.joined(separator: " "))
                                .font(.ui(14.5, .bold)).foregroundStyle(Palette.ink)
                            Text(v.registration ?? "Tap to edit")
                                .font(.ui(12.5)).foregroundStyle(Palette.ink3)
                        } else {
                            Text("Add your vehicle").font(.ui(14.5, .bold)).foregroundStyle(Palette.ink)
                            Text("Make, model & rego").font(.ui(12.5)).foregroundStyle(Palette.ink3)
                        }
                    }
                    Spacer(minLength: 0)
                    Icon(name: "chevR", size: 18, color: Palette.ink3)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.mileageAddVehicle)
    }

    @ViewBuilder private func logbookCard(_ vm: MileageViewModel) -> some View {
        Button { sheet = .logbook } label: {
            Card(padding: 14) {
                HStack(spacing: 12) {
                    IconCircle(name: "clock", tint: accent.base, soft: accent.soft, size: 38, iconSize: 19)
                    VStack(alignment: .leading, spacing: 1) {
                        if let s = vm.vehicle?.logbookStartDate, let e = vm.vehicle?.logbookEndDate {
                            Text("\(fmtDate(s)) – \(fmtDate(e))").font(.ui(14.5, .bold)).foregroundStyle(Palette.ink)
                            let validToSuffix: String = {
                                if let yr = Int(s.prefix(4)) { return " · valid to \(yr + 5)" }
                                return ""
                            }()
                            Text((vm.vehicle?.businessUsePct.map { "\($0)% business use" } ?? "Add trips to compute %") + validToSuffix)
                                .font(.ui(12.5)).foregroundStyle(Palette.ink3)
                        } else {
                            Text("Start your 12-week logbook").font(.ui(14.5, .bold)).foregroundStyle(Palette.ink)
                            Text("Builds your business-use %").font(.ui(12.5)).foregroundStyle(Palette.ink3)
                        }
                    }
                    Spacer(minLength: 0)
                    Icon(name: "chevR", size: 18, color: Palette.ink3)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.mileageStartLogbook)
    }

    /// GPS auto-track — non-functional placeholder (no location, no network).
    @ViewBuilder private var gpsCard: some View {
        Card(padding: 14) {
            HStack(spacing: 12) {
                IconCircle(name: "pin", tint: accent.base, soft: accent.soft, size: 38, iconSize: 19)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto-track with GPS").font(.ui(14.5, .bold)).foregroundStyle(Palette.ink)
                    Text("Coming soon").font(.ui(12.5)).foregroundStyle(Palette.ink3)
                }
                Spacer(minLength: 0)
                Capsule().fill(Palette.line).frame(width: 46, height: 28)
                    .overlay(Circle().fill(Palette.paper).frame(width: 22).padding(3), alignment: .leading)
            }
        }
        .opacity(0.7)
    }

    @ViewBuilder private func costsCard(_ vm: MileageViewModel) -> some View {
        let vy = vm.vehicleYear(fyStartYear: fyStartYear)
        let total = vy.map { $0.fuelCents + $0.regoCents + $0.insuranceCents + $0.servicingCents + $0.otherCents + $0.depreciationCents } ?? 0
        let claim = vm.currentClaimCents(fyStartYear: fyStartYear)
        Button { sheet = .costs } label: {
            Card(padding: 14) {
                HStack(spacing: 12) {
                    IconCircle(name: "wallet", tint: accent.base, soft: accent.soft, size: 38, iconSize: 19)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Running costs \(FinancialYear.label(startYear: fyStartYear))")
                            .font(.ui(14.5, .bold)).foregroundStyle(Palette.ink)
                        if let claim {
                            Text("\(fmt(total)) → claim \(fmt(claim))")
                                .font(.ui(12.5)).foregroundStyle(Palette.ink3)
                                .accessibilityIdentifier(AccessibilityID.mileageClaim)
                        } else {
                            Text("\(fmt(total)) · start your logbook for a claim")
                                .font(.ui(12.5)).foregroundStyle(Palette.ink3)
                        }
                    }
                    Spacer(minLength: 0)
                    Icon(name: "chevR", size: 18, color: Palette.ink3)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(vm.vehicle == nil)
        .opacity(vm.vehicle == nil ? 0.5 : 1)
        .accessibilityIdentifier(AccessibilityID.mileageEditCosts)
    }

    @ViewBuilder private func tripsList(_ vm: MileageViewModel) -> some View {
        if vm.trips.isEmpty {
            VStack(spacing: 12) {
                EmptyArt(size: 110)
                Text("No trips yet").font(.ui(14, .semibold)).foregroundStyle(Palette.ink2)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 24)
        } else {
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(vm.trips.enumerated()), id: \.element.id) { idx, t in
                        HStack(spacing: 12) {
                            IconCircle(name: "car",
                                       tint: t.isBusiness ? accent.base : Palette.ink3,
                                       soft: t.isBusiness ? accent.soft : Palette.paper2,
                                       size: 40, iconSize: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tripTitle(t)).font(.ui(14, .bold)).foregroundStyle(Palette.ink).lineLimit(1)
                                Text("\(fmtDate(t.tripDate)) · \(t.purpose ?? "")")
                                    .font(.ui(12.5)).foregroundStyle(Palette.ink3).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(String(format: "%.1f km", Double(t.distanceM) / 1000))
                                    .font(.ui(14.5, .bold)).foregroundStyle(Palette.ink)
                                Text(t.isBusiness ? "Business" : "Personal")
                                    .font(.ui(11, .bold))
                                    .foregroundStyle(t.isBusiness ? accent.base : Palette.ink3)
                            }
                        }
                        .padding(.vertical, 13).padding(.horizontal, 14)
                        if idx < vm.trips.count - 1 { Rectangle().fill(Palette.line2).frame(height: 1) }
                    }
                }
            }
        }
    }

    private func tripTitle(_ t: MileageTrip) -> String {
        if let f = t.fromLabel, let to = t.toLabel { return "\(f) → \(to)" }
        return t.purpose ?? "Trip"
    }

    // MARK: sheets

    @ViewBuilder private func sheetView(_ which: MileageSheet) -> some View {
        if let vm {
            switch which {
            case .vehicle: VehicleSheet(vm: vm) { sheet = nil }
            case .logbook: LogbookPeriodSheet(vm: vm) { sheet = nil }
            case .trip: AddTripSheet(vm: vm) { sheet = nil }
            case .costs: RunningCostsSheet(vm: vm, fyStartYear: fyStartYear, startMonth: startMonth) { sheet = nil }
            }
        }
    }
}

// MARK: - Vehicle sheet

private struct VehicleSheet: View {
    @Bindable var vm: MileageViewModel
    let onDone: () -> Void
    @State private var make = ""
    @State private var model = ""
    @State private var engineCc = ""
    @State private var registration = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Make", text: $make).accessibilityIdentifier(AccessibilityID.vehicleSheetMake)
                TextField("Model", text: $model).accessibilityIdentifier(AccessibilityID.vehicleSheetModel)
                TextField("Engine (cc, optional)", text: $engineCc).keyboardType(.numberPad)
                TextField("Registration", text: $registration)
            }
            .navigationTitle("Vehicle")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        vm.saveVehicle(make: make.nilIfBlank, model: model.nilIfBlank,
                                       engineCc: Int(engineCc), registration: registration.nilIfBlank)
                        onDone()
                    }
                    .accessibilityIdentifier(AccessibilityID.vehicleSheetSave)
                }
            }
        }
        .onAppear {
            make = vm.vehicle?.make ?? ""
            model = vm.vehicle?.model ?? ""
            engineCc = vm.vehicle?.engineCc.map(String.init) ?? ""
            registration = vm.vehicle?.registration ?? ""
        }
    }
}

// MARK: - Logbook period sheet

private struct LogbookPeriodSheet: View {
    @Bindable var vm: MileageViewModel
    let onDone: () -> Void
    @State private var start = Date()

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Start date", selection: $start, displayedComponents: .date)
                    .accessibilityIdentifier(AccessibilityID.logbookSheetStart)
                Text("12-week period ends \(fmtDate(MileageViewModel.autoEnd(from: ymd(start))))")
                    .font(.ui(12.5)).foregroundStyle(Palette.ink3)
                Text("A logbook is valid for 5 years.").font(.ui(12.5)).foregroundStyle(Palette.ink3)
                if let pct = vm.vehicle?.businessUsePct {
                    Text("Business use so far: \(pct)%").font(.ui(13, .semibold)).foregroundStyle(Palette.ink)
                }
            }
            .navigationTitle("Logbook period")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { vm.startLogbook(startDate: ymd(start)); onDone() }
                        .accessibilityIdentifier(AccessibilityID.logbookSheetSave)
                }
            }
        }
    }
}

// MARK: - Add trip sheet

private struct AddTripSheet: View {
    @Bindable var vm: MileageViewModel
    let onDone: () -> Void
    @State private var date = Date()
    @State private var odoStart = ""
    @State private var odoEnd = ""
    @State private var purpose = ""
    @State private var from = ""
    @State private var to = ""
    @State private var isBusiness = true

    private var startM: Int? { Double(odoStart).map { Int($0 * 1000) } }
    private var endM: Int? { Double(odoEnd).map { Int($0 * 1000) } }
    private var valid: Bool { MileageCalc.isValidOdometer(startM: startM, endM: endM) }
    private var km: Double { Double((endM ?? 0) - (startM ?? 0)) / 1000 }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Date", selection: $date, displayedComponents: .date)
                TextField("Odometer start (km)", text: $odoStart).keyboardType(.decimalPad)
                    .accessibilityIdentifier(AccessibilityID.tripSheetOdoStart)
                TextField("Odometer end (km)", text: $odoEnd).keyboardType(.decimalPad)
                    .accessibilityIdentifier(AccessibilityID.tripSheetOdoEnd)
                if valid {
                    Text(String(format: "Distance: %.1f km", km)).font(.ui(13, .semibold))
                } else if !odoStart.isEmpty || !odoEnd.isEmpty {
                    Text("End must be greater than start").font(.ui(12.5)).foregroundStyle(Palette.alert)
                }
                TextField("Purpose", text: $purpose)
                TextField("From (optional)", text: $from)
                TextField("To (optional)", text: $to)
                Toggle("Business trip", isOn: $isBusiness)
                    .accessibilityIdentifier(AccessibilityID.tripSheetBusiness)
            }
            .navigationTitle("Add a trip")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        vm.addTrip(date: ymd(date), odometerStartM: startM, odometerEndM: endM,
                                   isBusiness: isBusiness, purpose: purpose.nilIfBlank,
                                   fromLabel: from.nilIfBlank, toLabel: to.nilIfBlank)
                        onDone()
                    }
                    .disabled(!valid)
                    .accessibilityIdentifier(AccessibilityID.tripSheetSave)
                }
            }
        }
    }
}

// MARK: - Running costs sheet

private struct RunningCostsSheet: View {
    @Bindable var vm: MileageViewModel
    let fyStartYear: Int
    let startMonth: Int
    let onDone: () -> Void
    @State private var fuel = ""
    @State private var rego = ""
    @State private var insurance = ""
    @State private var servicing = ""
    @State private var other = ""
    @State private var depreciation = ""

    // Optional simplified depreciation helper (§5.4). Off by default — the user
    // can type a figure directly; toggling the helper computes it from the pure
    // `Depreciation` util and writes the result into `depreciation`.
    @State private var useHelper = false
    @State private var purchasePrice = ""
    @State private var purchaseDate = Date()
    @State private var method: Depreciation.Method = .diminishingValue

    private func cents(_ s: String) -> Int { Double(s).map { Int($0 * 100) } ?? 0 }

    /// Days from purchase to the end of the chosen FY (capped to a 365-day year),
    /// used for first-year part-year proration.
    private var daysHeld: Int {
        let fyEnd = FinancialYear.of(purchaseDate, startMonth: startMonth).end  // exclusive 1st of FY-start month next year
        let secs = fyEnd.timeIntervalSince(purchaseDate)
        let days = Int(secs / 86_400)
        return Swift.max(0, Swift.min(days, 365))
    }

    /// Recompute the depreciation figure from the helper inputs (8-yr car life).
    private func applyHelper() {
        let computed = Depreciation.declineCents(
            costCents: cents(purchasePrice), method: method,
            effectiveLifeYears: 8, daysHeld: daysHeld)
        depreciation = computed == 0 ? "" : String(format: "%.2f", Double(computed) / 100)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Annual running costs (\(FinancialYear.label(startYear: fyStartYear)))") {
                    TextField("Fuel", text: $fuel).keyboardType(.decimalPad)
                        .accessibilityIdentifier(AccessibilityID.costsSheetFuel)
                    TextField("Registration", text: $rego).keyboardType(.decimalPad)
                    TextField("Insurance", text: $insurance).keyboardType(.decimalPad)
                    TextField("Servicing", text: $servicing).keyboardType(.decimalPad)
                    TextField("Other", text: $other).keyboardType(.decimalPad)
                }
                Section("Depreciation (simplified estimate — not tax advice)") {
                    TextField("Depreciation", text: $depreciation).keyboardType(.decimalPad)
                    Toggle("Estimate it for me", isOn: $useHelper)
                    if useHelper {
                        TextField("Purchase price", text: $purchasePrice).keyboardType(.decimalPad)
                        DatePicker("Purchase date", selection: $purchaseDate, displayedComponents: .date)
                        Picker("Method", selection: $method) {
                            ForEach(Depreciation.Method.allCases) { m in Text(m.label).tag(m) }
                        }
                        Text("Capped at the $69,674 car cost limit; first year prorated by days held.")
                            .font(.ui(12)).foregroundStyle(Palette.ink3)
                    }
                }
                .onChange(of: useHelper) { _, on in if on { applyHelper() } }
                .onChange(of: purchasePrice) { _, _ in if useHelper { applyHelper() } }
                .onChange(of: purchaseDate) { _, _ in if useHelper { applyHelper() } }
                .onChange(of: method) { _, _ in if useHelper { applyHelper() } }
            }
            .navigationTitle("Running costs")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        vm.saveCosts(fyStartYear: fyStartYear, fuelCents: cents(fuel),
                                     regoCents: cents(rego), insuranceCents: cents(insurance),
                                     servicingCents: cents(servicing), otherCents: cents(other),
                                     depreciationCents: cents(depreciation))
                        onDone()
                    }
                    .accessibilityIdentifier(AccessibilityID.costsSheetSave)
                }
            }
        }
        .onAppear {
            guard let vy = vm.vehicleYear(fyStartYear: fyStartYear) else { return }
            fuel = dollars(vy.fuelCents); rego = dollars(vy.regoCents)
            insurance = dollars(vy.insuranceCents); servicing = dollars(vy.servicingCents)
            other = dollars(vy.otherCents); depreciation = dollars(vy.depreciationCents)
        }
    }

    private func dollars(_ cents: Int) -> String { cents == 0 ? "" : String(format: "%.2f", Double(cents) / 100) }
}

// MARK: - Sheet helpers

/// "yyyy-MM-dd" (UTC) for a Date — matches the app's ISO date storage.
private func ymd(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
}

private extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
