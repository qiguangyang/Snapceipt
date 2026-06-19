import SwiftUI
import SwiftData

/// The Reports tab (spec §5). Header + Export pill, Segmented period control, net-saved
/// trend (BarPair), "Where it went" Donut, Business-only tax pills + logbook rows, and
/// the AI insight card. Personal under-budget card is OMITTED (F3). A tab, not an overlay.
struct ReportsView: View {
    let context: ModelContext
    let userId: String
    let profileId: String
    let profileName: String
    let startMonth: Int
    let onOpenExport: (Period) -> Void
    let onOpenMileage: () -> Void
    let onOpenWFH: () -> Void
    /// Business + gstRegistered identity (drives the BAS card gate, spec §4.8).
    let profileType: String
    let gstRegistered: Bool
    let basDue: Date
    let basNetCents: Int
    let basLodged: Bool
    let onOpenBas: () -> Void

    @Environment(\.accent) private var accent
    @Environment(EntitlementStore.self) private var entitlement
    @State private var vm: ReportsViewModel?
    @State private var periodSelection: String = Period.month.rawValue
    @State private var showPaywall = false

    private let periodOptions = [
        SegmentOption(id: Period.month.rawValue, label: "Month"),
        SegmentOption(id: Period.quarter.rawValue, label: "Quarter"),
        SegmentOption(id: Period.fy.rawValue, label: "FY"),
    ]

    /// The BAS card is reachable ONLY for a GST-registered Business profile (spec §4.8).
    static func showsBasCard(profileType: String, gstRegistered: Bool) -> Bool {
        profileType == "business" && gstRegistered
    }

    var body: some View {
        ZStack {
            Palette.cream.ignoresSafeArea()
            if let vm {
                ScrollView {
                    VStack(spacing: 14) {
                        header
                        if Self.showsBasCard(profileType: profileType, gstRegistered: gstRegistered) {
                            basCard
                        }
                        Segmented(options: periodOptions, selection: $periodSelection)
                            .accessibilityIdentifier(AccessibilityID.reportsPeriod)
                        netCard(vm)
                        donutCard(vm)
                        if !vm.isBusiness, let ub = vm.underBudget { underBudgetCard(ub) }
                        if vm.isBusiness {
                            taxPills(vm)
                            logbookRows(vm)
                        }
                        insightCard(vm)
                    }
                    .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 110)
                }
            } else {
                Color.clear
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.reportsScreen)
        .task {
            if vm == nil {
                vm = ReportsViewModel(context: context, userId: userId,
                                      profileId: profileId, startMonth: startMonth)
            }
        }
        .onChange(of: periodSelection) { _, newValue in
            vm?.period = Period(rawValue: newValue) ?? .month
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
    }

    private var header: some View {
        HStack {
            Text("Reports").font(.display(28)).foregroundStyle(Palette.ink)
            Spacer()
            Button { onOpenExport(vm?.period ?? Period(rawValue: periodSelection) ?? .month) } label: {
                HStack(spacing: 6) {
                    Icon(name: "share", size: 17, color: .white)
                    Text("Export").font(.ui(13.5, .semibold)).foregroundStyle(.white)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(accent.base, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: accent.base.opacity(0.4), radius: 8, y: 8)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.reportsExportPill)
        }
    }

    private var basCard: some View {
        Button {
            guard entitlement.isPro else { showPaywall = true; return }
            onOpenBas()
        } label: {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("BAS · this quarter").font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
                    Text(basNetCents < 0 ? "ATO owes you \(fmt(-basNetCents))" : "\(fmt(basNetCents)) to pay")
                        .font(.display(24)).foregroundStyle(Palette.ink).monospacedDigit()
                    HStack {
                        Text("Due \(fmtBasDue(basDue))").font(.ui(13)).foregroundStyle(Palette.ink2)
                        Spacer()
                        Text("Review ›").font(.ui(13, .semibold)).foregroundStyle(accent.base)
                    }
                }
            }
            .contentShape(Rectangle())   // whole card tappable (Spacers aren't dead-zones)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.reportsBasCard)
    }

    private func netCard(_ vm: ReportsViewModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                // Period-aware caption (FY → "FY 2025–26", etc.); the net value below is
                // for the selected period while the BarPair trend always spans 5 months.
                Text("Net saved · \(vm.headline)").font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
                Text(fmt(vm.netCents)).font(.display(28)).foregroundStyle(Palette.ink)
                    .monospacedDigit()
                    .accessibilityIdentifier(AccessibilityID.reportsNet)
                HStack(spacing: 12) {
                    legendDot(color: Palette.income, label: "In")
                    legendDot(color: accent.base, label: "Out")
                }
                BarPair(data: vm.barData)
            }
        }
    }

    private func underBudgetCard(_ ub: (spentCents: Int, capCents: Int)) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    IconCircle(name: "star", tint: accent.base, soft: accent.soft, size: 40, iconSize: 20, filled: true)
                    Text("You're under budget").font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
                }
                Text("\(fmt(ub.spentCents)) of \(fmt(ub.capCents)) used")
                    .font(.ui(13)).foregroundStyle(Palette.ink2).monospacedDigit()
                ProgressBar(value: Double(ub.spentCents), max: Double(Swift.max(1, ub.capCents)), tint: accent.base)
            }
        }
        .accessibilityIdentifier(AccessibilityID.reportsUnderBudget)
    }

    private func donutCard(_ vm: ReportsViewModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Where it went").font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
                HStack(spacing: 18) {
                    Donut(segments: vm.donutSegments, size: 140, thickness: 20) {
                        VStack(spacing: 2) {
                            Text(fmtK(vm.donutTotalCents))
                                .font(.display(22)).foregroundStyle(Palette.ink).monospacedDigit()
                            Text("spent").font(.ui(11, .semibold)).foregroundStyle(Palette.ink3)
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.reportsDonut)
                    legend(vm)
                }
            }
        }
    }

    @ViewBuilder private func legend(_ vm: ReportsViewModel) -> some View {
        VStack(spacing: 9) {
            ForEach(Array(vm.legend.prefix(5).enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(tint(row.catKey)).frame(width: 9, height: 9)
                    Text(label(row.catKey)).font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink2)
                    Spacer()
                    Text(fmtK(row.spendCents)).font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink2).monospacedDigit()
                }
            }
        }
    }

    /// Compact dollar formatter: |v|≥$1000 → "$1.2k" (1 dp under $10k, else 0 dp);
    /// otherwise "$<int>". Leading minus preserved for negatives. Mirrors design fmtK.
    private func fmtK(_ cents: Int) -> String {
        let dollars = Double(cents) / 100
        let neg = dollars < 0
        let v = abs(dollars)
        let body: String
        if v >= 1000 {
            let k = v / 1000
            body = k < 10 ? String(format: "$%.1fk", k) : String(format: "$%.0fk", k)
        } else {
            body = "$\(Int(v))"
        }
        return neg ? "-\(body)" : body
    }

    private func taxPills(_ vm: ReportsViewModel) -> some View {
        HStack(spacing: 10) {
            pill("Deductible YTD", fmt(vm.deductibleYTDCents), icon: "shield", tint: Palette.income,
                 id: AccessibilityID.reportsDeductiblePill)
            pill("GST on purchases", fmt(vm.gstYTDCents), icon: "receipt", tint: accent.base,
                 id: AccessibilityID.reportsGstPill)
        }
    }

    private func pill(_ caption: String, _ value: String, icon: String, tint: Color, id: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Icon(name: icon, size: 20, color: tint)
                Text(value).font(.display(22)).foregroundStyle(Palette.ink).monospacedDigit()
                Text(caption).font(.ui(11.5, .semibold)).foregroundStyle(Palette.ink3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Merge caption + value into ONE accessibility element so the pill's label
        // carries its dollar amount (VoiceOver reads "Deductible YTD, $250.00" rather
        // than the bare caption). Without this the value Text is a sibling element and
        // the pill's label omits the figure entirely (J33 gap).
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    private func logbookRows(_ vm: ReportsViewModel) -> some View {
        VStack(spacing: 10) {
            logbookRow(icon: "car", tint: Color(hex: 0x2F6FB0), soft: Color(hex: 0xE2ECF6),
                       title: "Vehicle logbook",
                       value: fmt(vm.vehicleClaimCents), id: AccessibilityID.reportsLogbookVehicle,
                       action: onOpenMileage)
            logbookRow(icon: "wfh", tint: Color(hex: 0x0E7C72), soft: Color(hex: 0xDCF0ED),
                       title: "Working from home",
                       value: fmt(vm.wfhClaimCents), id: AccessibilityID.reportsLogbookWFH,
                       action: onOpenWFH)
        }
    }

    private func logbookRow(icon: String, tint: Color, soft: Color, title: String, value: String, id: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Card(padding: 14) {
                HStack(spacing: 12) {
                    IconCircle(name: icon, tint: tint, soft: soft, size: 38, iconSize: 19)
                    Text(title).font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                    Spacer()
                    Text(value).font(.ui(14.5, .semibold)).foregroundStyle(Palette.income).monospacedDigit()
                    Icon(name: "chevR", size: 16, color: Palette.ink3)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func insightCard(_ vm: ReportsViewModel) -> some View {
        // Accent-branded gradient card (screens.md §4 L385-388): gradient bg +
        // accent border + a "Snapceipt insight" header above the body copy.
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Icon(name: "sparkles", size: 18, color: accent.base)
                Text("Snapceipt insight").font(.ui(13.5, .semibold)).foregroundStyle(accent.deep)
            }
            Text(vm.insight).font(.ui(14)).foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            LinearGradient(colors: [accent.soft, Palette.paper],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(accent.base, lineWidth: 1)
        )
        .cardShadow()
        .accessibilityIdentifier(AccessibilityID.reportsInsight)
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(color).frame(width: 9, height: 9)
            Text(label).font(.ui(11.5, .semibold)).foregroundStyle(Palette.ink2)
        }
    }

    private func tint(_ key: String) -> Color {
        if let ck = CategoryKey(rawValue: key), let m = CATS[ck] { return m.tint }
        return Palette.ink3
    }
    private func label(_ key: String) -> String {
        if let ck = CategoryKey(rawValue: key), let m = CATS[ck] { return m.label }
        return key.capitalized
    }
}
