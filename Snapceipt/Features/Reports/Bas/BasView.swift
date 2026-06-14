import SwiftUI
import SwiftData

/// Full-screen BAS overlay (spec §4.7). Headline (net + due; "Estimated" until income
/// reviewed) + Simpler BAS spine (G1, 1A, 1B → net 9, PAYG 5A, total) with per-label
/// Copy + a myGov caption + a collapsible full-worksheet section + a TAPPABLE
/// reconciliation strip (confirm income / fix estimated GST) + Mark-as-lodged +
/// Export. Shown only for business + gstRegistered (gated by the caller).
struct BasView: View {
    let context: ModelContext
    let api: APIClient
    let userId: String
    let profileId: String
    let profileName: String
    let gstRegistered: Bool
    let basPeriod: BasPeriod
    let startMonth: Int
    let onOpenExport: () -> Void
    let onClose: () -> Void

    @Environment(\.accent) private var accent
    @State private var vm: BasViewModel?
    @State private var showFullWorksheet = false
    @State private var paygText = ""

    var body: some View {
        ZStack {
            Palette.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                SheetHeader(title: "BAS", onClose: onClose)
                if let vm {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            headline(vm)
                            spine(vm)
                            paygCard(vm)
                            reconcileStrip(vm)
                            fullWorksheetToggle(vm)
                            if showFullWorksheet { fullWorksheet(vm) }
                            actions(vm)
                        }
                        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 60)
                    }
                } else { Color.clear }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.basScreen)
        .keyboardDismissButton() // dismiss the numberPad on the PAYG (5A) field
        .transition(.opacity)
        .task {
            if vm == nil {
                let model = BasViewModel(context: context, api: api, store: BasLocalStore(),
                                         userId: userId, profileId: profileId,
                                         gstRegistered: gstRegistered, basPeriod: basPeriod,
                                         startMonth: startMonth, now: Epoch.now())
                paygText = model.paygInstalmentCents == 0 ? "" : fmtPlainDollars(model.paygInstalmentCents)
                vm = model
            }
        }
    }

    // MARK: Headline

    @ViewBuilder private func headline(_ vm: BasViewModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(vm.isHeadlineEstimated ? "Estimated" : "BAS this \(basPeriod == .quarterly ? "quarter" : "month")")
                        .font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
                    Spacer()
                    periodStepper(vm)
                }
                Text(netHeadline(vm)).font(.display(30)).foregroundStyle(Palette.ink).monospacedDigit()
                Text("Due \(fmtBasDue(vm.nextDue))").font(.ui(13.5)).foregroundStyle(Palette.ink2)
                if let lodgedAtMs = vm.lodgedAtMs {
                    Text("Lodged \(fmtBasDue(Date(timeIntervalSince1970: Double(lodgedAtMs) / 1000)))")
                        .font(.ui(12.5, .semibold)).foregroundStyle(accent.base)
                    if vm.hasDrifted {
                        Text("Figures changed since you lodged — corrections belong on your next BAS as an adjustment.")
                            .font(.ui(12)).foregroundStyle(Palette.alert)
                    }
                }
            }
        }
    }

    private func netHeadline(_ vm: BasViewModel) -> String {
        let net = vm.result.netGstCents
        return net < 0 ? "ATO owes you \(fmt(-net))" : "\(fmt(net)) to pay"
    }

    // The stepper is a non-functional placeholder in v1 (Period has no prior-period
    // API; the default window is the current in-progress period). Present for a11y.
    @ViewBuilder private func periodStepper(_ vm: BasViewModel) -> some View {
        Text(vm.window.label).font(.ui(13, .semibold)).foregroundStyle(Palette.ink2)
            .accessibilityIdentifier(AccessibilityID.basPeriodStepper)
    }

    // MARK: Simpler BAS spine

    @ViewBuilder private func spine(_ vm: BasViewModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Lodge these on your BAS").font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
                copyRow("G1 Total sales", vm.result.g1, id: AccessibilityID.basCopyG1)
                copyRow("1A GST on sales", vm.result.oneA, id: AccessibilityID.basCopy1A)
                copyRow("1B GST on purchases", vm.result.oneB, id: AccessibilityID.basCopy1B)
                Divider()
                plainRow("9 Net GST", vm.result.netGstCents)
                plainRow("5A PAYG instalment", vm.result.paygCents)
                plainRow("Total", vm.result.totalPayableCents)
                Text("Type these into the matching boxes in the myGov / ATO BAS form.")
                    .font(.ui(12)).foregroundStyle(Palette.ink3)
            }
        }
    }

    private func copyRow(_ label: String, _ cents: Int, id: String) -> some View {
        HStack {
            Text(label).font(.ui(14)).foregroundStyle(Palette.ink2)
            Spacer()
            Text(fmt(cents)).font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink).monospacedDigit()
            Button {
                UIPasteboard.general.string = String(format: "%.0f", Double(cents) / 100.0)
            } label: { Icon(name: "chart", size: 15, color: accent.base) }
            .buttonStyle(.plain)
            .accessibilityIdentifier(id)
        }
    }

    private func plainRow(_ label: String, _ cents: Int) -> some View {
        HStack {
            Text(label).font(.ui(14)).foregroundStyle(Palette.ink2); Spacer()
            Text(fmt(cents)).font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink).monospacedDigit()
        }
    }

    // MARK: PAYG

    @ViewBuilder private func paygCard(_ vm: BasViewModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text("PAYG instalment (5A)").font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
                TextField("0", text: $paygText).keyboardType(.numberPad)
                    .padding(12).background(Palette.paper2, in: RoundedRectangle(cornerRadius: 12))
                    .onChange(of: paygText) { _, v in vm.setPaygInstalmentCents((Int(v) ?? 0) * 100) }
                    .accessibilityIdentifier(AccessibilityID.basPaygField)
            }
        }
    }

    // MARK: Reconciliation strip (tappable quick-fix)

    @ViewBuilder private func reconcileStrip(_ vm: BasViewModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                if vm.estimatedGstCount == 0 && vm.incomeToConfirmCount == 0 && vm.printedDiscrepancyCount == 0 {
                    Text("Looks complete").font(.ui(14.5, .semibold)).foregroundStyle(accent.base)
                } else {
                    if vm.incomeToConfirmCount > 0 {
                        Button { vm.confirmAllIncome() } label: {
                            reconcileRowLabel(
                                "\(vm.incomeToConfirmCount) income entries — tap to confirm taxable",
                                cta: "Confirm")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(AccessibilityID.basConfirmIncome)
                    }
                    if vm.estimatedGstCount > 0 {
                        // Quick-fix: mark the first estimated expense GST-free. (A richer
                        // per-row editor lives in capture review; this is the in-strip fast path.)
                        Button {
                            if let item = vm.reconcileItems.first(where: { $0.amountCents < 0 && $0.gstSource == "derived" }) {
                                vm.fixEstimatedAsGstFree(itemId: item.id)
                            }
                        } label: {
                            reconcileRowLabel(
                                "\(vm.estimatedGstCount) purchases used estimated GST — tap to mark GST-free",
                                cta: "Fix")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(AccessibilityID.basReconcileRowPrefix + "estimated")
                    }
                    if vm.printedDiscrepancyCount > 0 {
                        Text("\(vm.printedDiscrepancyCount) receipts where the printed GST disagrees — check the split in the receipt")
                            .font(.ui(13.5)).foregroundStyle(Palette.ink2)
                            .accessibilityIdentifier(AccessibilityID.basReconcileRowPrefix + "printed")
                    }
                }
            }
        }
    }

    private func reconcileRowLabel(_ text: String, cta: String) -> some View {
        HStack {
            Text(text).font(.ui(13.5)).foregroundStyle(Palette.ink2).multilineTextAlignment(.leading)
            Spacer()
            Text(cta).font(.ui(13, .semibold)).foregroundStyle(accent.base)
        }
    }

    // MARK: Full worksheet (≥$10M) toggle

    @ViewBuilder private func fullWorksheetToggle(_ vm: BasViewModel) -> some View {
        Button { showFullWorksheet.toggle() } label: {
            HStack {
                Text("Full reporting method (≥$10M) — not on your Simpler BAS")
                    .font(.ui(13.5, .semibold)).foregroundStyle(accent.base)
                Spacer()
                Icon(name: "chevD", size: 14, color: accent.base)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.basFullWorksheetToggle)
    }

    @ViewBuilder private func fullWorksheet(_ vm: BasViewModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                plainRow("G2 Exports", vm.result.g2)
                plainRow("G3 Other GST-free sales", vm.result.g3)
                plainRow("G10 Capital purchases", vm.result.g10)
                plainRow("G11 Non-capital purchases", vm.result.g11)
                plainRow("G14 GST-free purchases", vm.result.g14)
                plainRow("G17 Total purchases subject to GST", vm.result.g17)
            }
        }
    }

    // MARK: Actions

    @ViewBuilder private func actions(_ vm: BasViewModel) -> some View {
        VStack(spacing: 10) {
            Button { vm.markAsLodged() } label: {
                Text("Mark as lodged").font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                        .strokeBorder(Palette.line2, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.basMarkLodged)

            Button { onOpenExport() } label: {
                Text("Export BAS pack").font(.ui(15.5, .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(accent.base, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.basExport)
        }
    }
}

/// Whole-dollar plain string for the PAYG field prefill (no currency symbol).
private func fmtPlainDollars(_ cents: Int) -> String { String(cents / 100) }
