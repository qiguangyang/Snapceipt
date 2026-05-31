import SwiftUI
import SwiftData

/// Full-screen work-from-home overlay (ATO fixed-rate method, 70c/hr). (§6.2)
struct WFHScreen: View {
    let context: ModelContext
    let sync: any SyncEnqueuing
    let userId: String
    let profileId: String
    let startMonth: Int
    let onClose: () -> Void

    @Environment(\.accent) private var accent
    @State private var vm: WFHViewModel?
    @State private var showSheet = false

    private static let dow = ["M", "T", "W", "T", "F", "S", "S"]
    private var fyStartYear: Int { FinancialYear.of(Date(), startMonth: startMonth).startYear }

    private func rate() -> Int {
        let pid = profileId
        var d = FetchDescriptor<TaxSettings>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first?.wfhRateCentsPerHour ?? 70
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Palette.cream.ignoresSafeArea()
            if let vm {
                VStack(spacing: 0) {
                    LbHeader(title: "Work from home", onClose: onClose, onAdd: { showSheet = true })
                    ScrollView {
                        VStack(spacing: 0) {
                            hero(vm)
                            weekChart(vm).padding(.top, 14)
                            LbLabel(text: "Logged days")
                            daysList(vm)
                            explainer(vm).padding(.top, 16)
                        }
                        .padding(.horizontal, 18).padding(.bottom, 110)
                    }
                }
                LbFloatingCTA(title: "Log hours", a11yId: AccessibilityID.wfhLogHours) { showSheet = true }
            } else {
                Color.clear
            }
        }
        .accessibilityIdentifier(AccessibilityID.wfhScreen)
        .transition(.opacity)
        .task {
            TaxSettingsSeeder.ensure(profileId: profileId, userId: userId, context: context, sync: sync)
            if vm == nil {
                vm = WFHViewModel(context: context, sync: sync, userId: userId,
                                  profileId: profileId, rateCentsPerHour: rate(), startMonth: startMonth)
            }
        }
        .sheet(isPresented: $showSheet) {
            if let vm { LogHoursSheet(vm: vm) { showSheet = false } }
        }
    }

    @ViewBuilder private func hero(_ vm: WFHViewModel) -> some View {
        let h = vm.hero(fyStartYear: fyStartYear)
        let hours = Double(h.totalMinutes) / 60.0
        LbHero(icon: "wfh", label: "This financial year",
               pill: "\(vm.rateCentsPerHour)c / hour",
               bigNumber: String(format: "%.1f", hours), unit: "hrs",
               stats: [
                    ("Claimable", fmt(h.claimCents)),
                    ("Days logged", "\(h.daysLogged)"),
                    ("Avg / day", String(format: "%.1fh", h.avgHoursPerDay)),
               ])
    }

    @ViewBuilder private func weekChart(_ vm: WFHViewModel) -> some View {
        let minutes = vm.thisWeekMinutes()
        let hoursPerDay = minutes.map { Double($0) / 60.0 }
        let weekMax = hoursPerDay.max() ?? 0
        let scale = Swift.max(8.0, weekMax)
        let weekTotal = hoursPerDay.reduce(0, +)
        Card(padding: 18) {
            VStack(spacing: 0) {
                HStack {
                    Text("This week").font(.ui(14.5, .bold)).foregroundStyle(Palette.ink)
                    Spacer()
                    Text(String(format: "%.1f hrs", weekTotal))
                        .font(.ui(13, .semibold)).foregroundStyle(Palette.ink3)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(0..<7, id: \.self) { i in
                        VStack(spacing: 6) {
                            ZStack(alignment: .bottom) {
                                Color.clear.frame(height: 70)
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(hoursPerDay[i] > 0 ? accent.base : Palette.line)
                                    .frame(height: Swift.max(hoursPerDay[i] / scale * 70, 3))
                            }
                            .frame(maxWidth: 26)
                            Text(Self.dow[i]).font(.ui(11, .semibold)).foregroundStyle(Palette.ink3)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 96).padding(.top, 14)
            }
        }
    }

    @ViewBuilder private func daysList(_ vm: WFHViewModel) -> some View {
        if vm.logs.isEmpty {
            VStack(spacing: 12) {
                EmptyArt(size: 110)
                Text("No hours logged yet").font(.ui(14, .semibold)).foregroundStyle(Palette.ink2)
                Text("Log hours as you work them — the ATO no longer accepts after-the-fact estimates.")
                    .font(.ui(12.5)).foregroundStyle(Palette.ink3).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 24).padding(.horizontal, 16)
        } else {
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(vm.logs.enumerated()), id: \.element.id) { idx, log in
                        HStack(spacing: 12) {
                            IconCircle(name: "clock", tint: accent.base, soft: accent.soft, size: 40, iconSize: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(fmtDate(log.logDate, style: .long)).font(.ui(14.5, .bold)).foregroundStyle(Palette.ink)
                                if let note = log.note, !note.isEmpty {
                                    Text(note).font(.ui(12.5)).foregroundStyle(Palette.ink3).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            Text(String(format: "%.1f h", Double(log.minutes) / 60))
                                .font(.ui(15, .bold)).foregroundStyle(Palette.ink)
                        }
                        .padding(.vertical, 13).padding(.horizontal, 14)
                        if idx < vm.logs.count - 1 { Rectangle().fill(Palette.line2).frame(height: 1) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func explainer(_ vm: WFHViewModel) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Icon(name: "info", size: 18, color: Palette.ink3).padding(.top, 1)
            Text("The \(vm.rateCentsPerHour)c fixed rate covers electricity, gas, internet, phone & stationery. No need to keep separate bills.")
                .font(.ui(12.5)).foregroundStyle(Palette.ink2).lineSpacing(2)
        }
        .padding(14)
        .background(Palette.paper2, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
    }
}

// MARK: - Log hours sheet

private struct LogHoursSheet: View {
    @Bindable var vm: WFHViewModel
    let onDone: () -> Void
    @State private var date = Date()
    @State private var hours = ""
    @State private var note = ""

    private var minutes: Int { Int((Double(hours) ?? 0) * 60) }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Date", selection: $date, displayedComponents: .date)
                TextField("Hours", text: $hours).keyboardType(.decimalPad)
                    .accessibilityIdentifier(AccessibilityID.wfhSheetHours)
                TextField("Note (optional)", text: $note)
            }
            .navigationTitle("Log hours")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        vm.logHours(date: ymdWFH(date), minutes: minutes, note: note.isEmpty ? nil : note)
                        onDone()
                    }
                    .disabled(minutes <= 0)
                    .accessibilityIdentifier(AccessibilityID.wfhSheetSave)
                }
            }
            .onChange(of: date) { _, _ in prefill() }
            .onAppear { prefill() }
        }
    }

    /// Pre-fill the form when the chosen date already has a log (one-per-day edit).
    private func prefill() {
        if let existing = vm.existingLog(for: ymdWFH(date)) {
            hours = String(format: "%.1f", Double(existing.minutes) / 60)
            note = existing.note ?? ""
        }
    }
}

/// "yyyy-MM-dd" (UTC) for a Date.
private func ymdWFH(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
}
