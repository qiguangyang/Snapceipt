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

    @Environment(\.accent) private var accent
    @State private var vm: ReportsViewModel?
    @State private var periodSelection: String = Period.month.rawValue

    private let periodOptions = [
        SegmentOption(id: Period.month.rawValue, label: "Month"),
        SegmentOption(id: Period.quarter.rawValue, label: "Quarter"),
        SegmentOption(id: Period.fy.rawValue, label: "FY"),
    ]

    var body: some View {
        ZStack {
            Palette.cream.ignoresSafeArea()
            if let vm {
                ScrollView {
                    VStack(spacing: 14) {
                        header
                        Segmented(options: periodOptions, selection: $periodSelection)
                            .accessibilityIdentifier(AccessibilityID.reportsPeriod)
                        netCard(vm)
                        if !vm.isBusiness, let ub = vm.underBudget { underBudgetCard(ub) }
                        donutCard(vm)
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
    }

    private var header: some View {
        HStack {
            Text("Reports").font(.display(28)).foregroundStyle(Palette.ink)
            Spacer()
            Button { onOpenExport(vm?.period ?? Period(rawValue: periodSelection) ?? .month) } label: {
                HStack(spacing: 6) {
                    Icon(name: "chart", size: 16, color: accent.base)
                    Text("Export").font(.ui(13.5, .semibold)).foregroundStyle(accent.base)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(accent.soft, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.reportsExportPill)
        }
    }

    private func netCard(_ vm: ReportsViewModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Net saved · \(vm.headline)").font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
                Text(fmt(vm.netCents)).font(.display(30)).foregroundStyle(Palette.ink)
                    .monospacedDigit()
                    .accessibilityIdentifier(AccessibilityID.reportsNet)
                HStack(spacing: 14) {
                    legendDot(color: Palette.income, label: "In \(fmt(vm.incomeCents))")
                    legendDot(color: accent.base, label: "Out \(fmt(vm.expenseCents))")
                }
                BarPair(data: vm.barData)
            }
        }
    }

    private func underBudgetCard(_ ub: (spentCents: Int, capCents: Int)) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    IconCircle(name: "check", tint: accent.base, soft: accent.soft, size: 34, iconSize: 17)
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
            VStack(spacing: 12) {
                HStack {
                    Text("Where it went").font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
                    Spacer()
                }
                Donut(segments: vm.donutSegments, size: 150, thickness: 22) {
                    VStack(spacing: 2) {
                        Text(fmt(vm.donutTotalCents, showCents: false))
                            .font(.display(20)).foregroundStyle(Palette.ink).monospacedDigit()
                        Text("spent").font(.ui(11, .semibold)).foregroundStyle(Palette.ink3)
                    }
                }
                .accessibilityIdentifier(AccessibilityID.reportsDonut)
                legend(vm)
            }
        }
    }

    @ViewBuilder private func legend(_ vm: ReportsViewModel) -> some View {
        VStack(spacing: 6) {
            ForEach(Array(vm.legend.prefix(5).enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    Circle().fill(tint(row.catKey)).frame(width: 9, height: 9)
                    Text(label(row.catKey)).font(.ui(13)).foregroundStyle(Palette.ink2)
                    Spacer()
                    Text(fmt(row.spendCents)).font(.ui(13, .semibold)).foregroundStyle(Palette.ink).monospacedDigit()
                }
            }
        }
    }

    private func taxPills(_ vm: ReportsViewModel) -> some View {
        HStack(spacing: 10) {
            pill("Deductible YTD", fmt(vm.deductibleYTDCents), id: AccessibilityID.reportsDeductiblePill)
            pill("GST on purchases", fmt(vm.gstYTDCents), id: AccessibilityID.reportsGstPill)
        }
    }

    private func pill(_ caption: String, _ value: String, id: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text(caption).font(.ui(11.5, .semibold)).foregroundStyle(Palette.ink3)
                Text(value).font(.display(18)).foregroundStyle(Palette.ink).monospacedDigit()
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
            logbookRow(icon: "car", title: "Vehicle logbook",
                       value: fmt(vm.vehicleClaimCents), id: AccessibilityID.reportsLogbookVehicle,
                       action: onOpenMileage)
            logbookRow(icon: "wfh", title: "Work from home",
                       value: fmt(vm.wfhClaimCents), id: AccessibilityID.reportsLogbookWFH,
                       action: onOpenWFH)
        }
    }

    private func logbookRow(icon: String, title: String, value: String, id: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Card(padding: 14) {
                HStack(spacing: 12) {
                    IconCircle(name: icon, tint: accent.base, soft: accent.soft, size: 38, iconSize: 19)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                        Text("FY claim \(value)").font(.ui(12)).foregroundStyle(Palette.ink3).monospacedDigit()
                    }
                    Spacer()
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
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label).font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink2).monospacedDigit()
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
