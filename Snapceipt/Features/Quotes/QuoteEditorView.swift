import SwiftUI
import SwiftData

/// Full-screen quote editor. Bill-to client (-> ClientPickerSheet), inline line items,
/// a GST toggle, live totals, and Send (-> APIClient.sendQuote). On success shows a
/// success overlay; when email is off it offers "View PDF" via a share sheet.
struct QuoteEditorView: View {
    let context: ModelContext
    let sync: any SyncEnqueuing
    let api: APIClient
    let userId: String
    let profileId: String
    let quoteId: String?          // nil = new
    let onClose: () -> Void

    @Environment(\.accent) private var accent
    @State private var vm: QuoteEditorViewModel?
    @State private var showClientPicker = false
    @State private var sent = false
    @State private var shareURL: URL?

    var body: some View {
        ZStack(alignment: .bottom) {
            Palette.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                SheetHeader(title: quoteId == nil ? "New quote" : "Quote", onClose: onClose)
                if let vm { content(vm) } else { Color.clear }
            }
            if let vm { sendBar(vm) }
            if sent, let vm { successOverlay(vm) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.quoteEditorScreen)
        .transition(.opacity)
        // Success haptic when the quote send succeeds (drives the success overlay).
        .sensoryFeedback(.success, trigger: sent)
        .task {
            if vm == nil {
                let model = QuoteEditorViewModel(context: context, sync: sync,
                                                 userId: userId, profileId: profileId)
                model.load(id: quoteId)
                vm = model
            }
        }
        .sheet(isPresented: $showClientPicker) {
            if let vm {
                ClientPickerSheet(context: context, sync: sync, userId: userId, profileId: profileId,
                                  onPick: { name, email in
                                      vm.setClient(name: name, email: email)
                                      showClientPicker = false
                                  },
                                  onClose: { showClientPicker = false })
                    .environment(\.accent, accent)
            }
        }
        .sheet(item: shareItem) { item in QuoteActivityView(url: item.url) }
    }

    @ViewBuilder private func content(_ vm: QuoteEditorViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                numberBadge(vm)
                billToCard(vm)
                lineItemsSection(vm)
                gstRow(vm)
                totalsCard(vm)
                Text("Valid for 14 days. Accepted quotes convert to an invoice.")
                    .font(.ui(11.5)).foregroundStyle(Palette.ink3)
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 120)
        }
    }

    private func numberBadge(_ vm: QuoteEditorViewModel) -> some View {
        HStack {
            Text(vm.displayNumber).font(.ui(13, .bold)).foregroundStyle(accent.base)
                .padding(.vertical, 5).padding(.horizontal, 12)
                .background(accent.soft, in: Capsule())
            Spacer()
        }
    }

    @ViewBuilder private func billToCard(_ vm: QuoteEditorViewModel) -> some View {
        Button { showClientPicker = true } label: {
            HStack(spacing: 12) {
                IconCircle(name: "building", tint: accent.base, soft: accent.soft, size: 40, iconSize: 19)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.clientName ?? "Choose a client").font(.ui(14.5, .semibold))
                        .foregroundStyle(vm.clientName == nil ? Palette.ink3 : Palette.ink)
                    if let email = vm.clientEmail {
                        Text(email).font(.ui(12)).foregroundStyle(Palette.ink3)
                    }
                }
                Spacer()
                Icon(name: "chevR", size: 14, color: Palette.ink3)
            }
            .padding(12)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.line2, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.quoteEditorClient)
    }

    @ViewBuilder private func lineItemsSection(_ vm: QuoteEditorViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Line items").font(.ui(12.5, .bold)).foregroundStyle(Palette.ink3)
            ForEach(vm.lineItems) { line in
                lineRow(vm, line)
                    .accessibilityIdentifier(AccessibilityID.quoteLineRowPrefix + line.id)
            }
            Button { vm.addLine() } label: {
                HStack(spacing: 8) {
                    Icon(name: "plus", size: 16, color: accent.base, lineWidth: 2)
                    Text("Add line item").font(.ui(14.5, .semibold)).foregroundStyle(accent.base)
                    Spacer()
                }
                .padding(12)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(accent.base.opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.quoteEditorAddLine)
        }
    }

    private func lineRow(_ vm: QuoteEditorViewModel, _ line: QuoteLineItem) -> some View {
        VStack(spacing: 8) {
            TextField("Description", text: Binding(
                get: { line.itemDescription }, set: { line.itemDescription = $0 }))
                .padding(10).background(Palette.cream, in: RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 8) {
                TextField("Qty", text: Binding(
                    get: { String(line.quantity) },
                    set: { line.quantity = max(1, Int($0.filter(\.isNumber)) ?? 1) }))
                    .keyboardType(.numberPad)
                    .padding(10).frame(width: 70).background(Palette.cream, in: RoundedRectangle(cornerRadius: 10))
                TextField("Unit $", text: Binding(
                    get: { String(line.unitPriceCents / 100) },
                    set: { line.unitPriceCents = (Int($0.filter(\.isNumber)) ?? 0) * 100 }))
                    .keyboardType(.numberPad)
                    .padding(10).background(Palette.cream, in: RoundedRectangle(cornerRadius: 10))
                Text(fmt(line.lineTotalCents)).font(.ui(13, .semibold)).foregroundStyle(Palette.ink2).monospacedDigit()
                Button { vm.removeLine(line) } label: {
                    Icon(name: "close", size: 16, color: Palette.ink3)
                }.buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func gstRow(_ vm: QuoteEditorViewModel) -> some View {
        Toggle(isOn: Binding(get: { vm.gstEnabled }, set: { vm.gstEnabled = $0 })) {
            Text("Add GST (10%)").font(.ui(14, .semibold)).foregroundStyle(Palette.ink)
        }
        .tint(accent.base)
        .padding(12)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier(AccessibilityID.quoteEditorGst)
    }

    private func totalsCard(_ vm: QuoteEditorViewModel) -> some View {
        let t = vm.totals
        return VStack(spacing: 8) {
            totalRow("Subtotal", fmt(t.subtotal), bold: false)
            // Hairline between each ledger line (design ref: screens.md §9 totals card).
            Divider().overlay(Palette.line2)
            if vm.gstEnabled {
                totalRow("GST (10%)", fmt(t.gst), bold: false)
                Divider().overlay(Palette.line2)
            }
            totalRow("Total", fmt(t.total), bold: true)
        }
        .padding(14)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    private func totalRow(_ label: String, _ value: String, bold: Bool) -> some View {
        HStack {
            Text(label).font(.ui(bold ? 15 : 13.5, bold ? .bold : .regular)).foregroundStyle(Palette.ink2)
            Spacer()
            Text(value).font(.ui(bold ? 16 : 14, .semibold)).foregroundStyle(Palette.ink).monospacedDigit()
        }
    }

    @ViewBuilder private func sendBar(_ vm: QuoteEditorViewModel) -> some View {
        VStack(spacing: 6) {
            if let err = vm.errorMessage {
                Text(err).font(.ui(12.5)).foregroundStyle(Palette.alert)
            }
            Button {
                Task {
                    if await vm.send(api: api) {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { sent = true }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if vm.isSending { ProgressView().tint(.white) }
                    Text(vm.isSending ? "Sending…" : "Send quote").font(.ui(16, .semibold)).foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(accent.base, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                // Disabled = faded accent (house pattern: Onboarding Continue .5, Reports CTA .45),
                // not an opaque grey swap.
                .opacity(vm.canSend ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .disabled(!vm.canSend || vm.isSending)
            .accessibilityIdentifier(AccessibilityID.quoteEditorSend)
        }
        .padding(.horizontal, 18).padding(.bottom, 26)
    }

    private func successOverlay(_ vm: QuoteEditorViewModel) -> some View {
        ZStack {
            Palette.cream.opacity(0.97).ignoresSafeArea()
            VStack(spacing: 14) {
                ZStack {
                    Circle().fill(Palette.income).frame(width: 72, height: 72)
                    Icon(name: "check", size: 34, color: .white, lineWidth: 3)
                }
                Text(vm.emailed ? "Quote sent!" : "Quote ready!").font(.display(20, .bold)).foregroundStyle(Palette.ink)
                Text("\(vm.displayNumber) · \(fmt(vm.totals.total))").font(.ui(14)).foregroundStyle(Palette.ink2)
                if !vm.emailed, vm.pdfUrl != nil {
                    Button { openPDF(vm) } label: {
                        Text("View PDF").font(.ui(15, .semibold)).foregroundStyle(.white)
                            .frame(minWidth: 160, minHeight: 46)
                            .background(accent.base, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }.buttonStyle(.plain)
                }
                Button { onClose() } label: {
                    Text("Done").font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
                        .frame(minWidth: 160, minHeight: 46)
                        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line, lineWidth: 1))
                }.buttonStyle(.plain)
            }
        }
        .transition(.opacity)
    }

    private func openPDF(_ vm: QuoteEditorViewModel) {
        guard let url = vm.pdfUrl else { return }
        let full = url.hasPrefix("http") ? url : "https://api.snapceipt.cc\(url)"
        shareURL = URL(string: full)
    }

    private struct ShareItem: Identifiable { let id = UUID(); let url: URL }
    private var shareItem: Binding<ShareItem?> {
        Binding(get: { shareURL.map { ShareItem(url: $0) } },
                set: { if $0 == nil { shareURL = nil } })
    }
}

/// UIActivityViewController bridge for the optional "View PDF" share.
private struct QuoteActivityView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
