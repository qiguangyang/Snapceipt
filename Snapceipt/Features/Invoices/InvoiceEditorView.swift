import SwiftUI
import SwiftData

/// Full-screen invoice editor (near-mirror of `QuoteEditorView`). Bill-to client,
/// inline line items, GST toggles, a due-date picker, live totals. Draft → "Issue
/// invoice" + PDF share. Issued → "Send invoice" + "Record payment" + PDF + badge.
struct InvoiceEditorView: View {
    let context: ModelContext
    let sync: any SyncEnqueuing
    let api: APIClient
    let userId: String
    let profileId: String
    let invoiceId: String?           // nil = new
    let onClose: () -> Void
    var onSavedDraft: (() -> Void)? = nil
    var showsRepeatReview = false

    @Environment(\.accent) private var accent
    @State private var vm: InvoiceEditorViewModel?
    @State private var showClientPicker = false
    @State private var showCatalogPicker = false
    @State private var showRecordPayment = false
    @State private var shareURL: URL?
    @State private var sent = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Palette.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if showsRepeatReview {
                    Text("Review prices and dates before sending.")
                        .font(.ui(13, .semibold)).foregroundStyle(Palette.ink2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18).padding(.bottom, 12)
                        .accessibilityIdentifier(AccessibilityID.clientRepeatReview)
                }
                if let vm { content(vm) } else { Color.clear }
            }
            if let vm { actionBar(vm).ignoresSafeArea(.keyboard, edges: .bottom) }
            if sent, let vm { successOverlay(vm) }
        }
        .sensoryFeedback(.success, trigger: sent)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.invoiceEditorScreen)
        .transition(.opacity)
        .task {
            if vm == nil {
                let model = InvoiceEditorViewModel(context: context, sync: sync, userId: userId, profileId: profileId)
                model.load(id: invoiceId)
                vm = model
            }
        }
        .sheet(isPresented: $showCatalogPicker) {
            if let vm {
                CatalogPickerSheet(context: context, sync: sync, userId: userId, profileId: profileId,
                    onPick: { item in
                        _ = try vm.addCatalogItem(item)
                        showCatalogPicker = false
                    }, onClose: { showCatalogPicker = false })
            }
        }
        .sheet(isPresented: $showClientPicker) {
            if let vm {
                ClientPickerSheet(context: context, sync: sync, userId: userId, profileId: profileId,
                                  // clientAddress + clientMobile are scoped to QUOTES only — invoices ignore them.
                                  onPick: { selection in vm.setClient(selection); showClientPicker = false },
                                  onClose: { showClientPicker = false })
                    .environment(\.accent, accent)
            }
        }
        .sheet(isPresented: $showRecordPayment) {
            if let vm, let iid = vm.invoiceId {
                RecordPaymentSheet(context: context, sync: sync, userId: userId, invoiceId: iid,
                                   onClose: { showRecordPayment = false; vm.load(id: iid) })
                    .environment(\.accent, accent)
                    .presentationDetents([.medium])
            }
        }
        .sheet(item: shareItem) { item in InvoiceActivityView(url: item.url) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                Icon(name: "close", size: 18, color: Palette.ink2)
                    .frame(width: 40, height: 40)
                    .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.logbookClose)
            .accessibilityLabel("Close")
            Text(invoiceId == nil ? "New invoice" : "Invoice").font(.ui(16, .bold)).foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity).lineLimit(1)
            Text(vm?.displayNumber ?? "Draft").font(.ui(12.5, .bold)).foregroundStyle(Palette.ink3)
                .lineLimit(1).frame(minWidth: 40, alignment: .trailing)
        }
        .padding(.top, 12).padding(.horizontal, 18).padding(.bottom, 12)
    }

    @ViewBuilder private func content(_ vm: InvoiceEditorViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let qid = vm.quoteId { fromQuoteNote(qid) }
                if vm.status != "draft" { badgeRow(vm) }
                if vm.status == "draft", onSavedDraft != nil {
                    Button("Save Draft") { saveDraft(vm) }
                        .accessibilityIdentifier(AccessibilityID.invoiceEditorSaveDraft)
                }
                billToSection(vm)
                lineItemsSection(vm)
                dueDateSection(vm)
                totalsCard(vm)
            }
            .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 130)
        }
        .keyboardDismissButton()
    }

    func saveDraft(_ vm: InvoiceEditorViewModel) {
        if vm.saveDraft() { onSavedDraft?() }
    }

    private func fromQuoteNote(_ quoteId: String) -> some View {
        HStack(spacing: 8) {
            Icon(name: "receipt", size: 14, color: Palette.ink3)
            Text("From quote").font(.ui(12.5)).foregroundStyle(Palette.ink2)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Palette.paper2, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        .accessibilityIdentifier(AccessibilityID.invoiceEditorConvertFromQuote)
    }

    /// A/R status display for an issued invoice: the payment-state badge
    /// (Unpaid/Partial/Paid — paid is income green, else neutral ink-3) plus a soft-amber
    /// "Overdue" pill when past the due date. Soft framing: overdue uses `Palette.warn`,
    /// never `Palette.alert` red. Mirrors `InvoiceListView`'s badge treatment.
    @ViewBuilder private func badgeRow(_ vm: InvoiceEditorViewModel) -> some View {
        let badge = vm.badge
        let overdue = AccountsReceivable.isOverdue(
            status: vm.status, paymentState: badge, dueDate: vm.dueDate,
            today: ExportDateFormatter.shared.string(from: Date()))
        HStack(spacing: 6) {
            statusPill(text: paymentLabel(badge), color: paymentColor(badge))
            if overdue { statusPill(text: "Overdue", color: Palette.warn) }
            Spacer()
        }
    }

    private func statusPill(text: String, color: Color) -> some View {
        Text(text).font(.ui(11.5, .bold)).foregroundStyle(color)
            .padding(.vertical, 3).padding(.horizontal, 10)
            .background(color.opacity(0.14), in: Capsule())
    }

    private func paymentLabel(_ badge: InvoiceBadge) -> String {
        switch badge {
        case .unpaid: return "Unpaid"
        case .partial: return "Partial"
        case .paid: return "Paid"
        }
    }

    private func paymentColor(_ badge: InvoiceBadge) -> Color {
        badge == .paid ? Palette.income : Palette.ink3
    }

    @ViewBuilder private func billToSection(_ vm: InvoiceEditorViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            groupLabel("Bill to")
            Button { showClientPicker = true } label: {
                Card(padding: 14) {
                    HStack(spacing: 12) {
                        clientInitials(vm.clientName)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(vm.clientName ?? "Choose a client").font(.ui(15, .bold))
                                .foregroundStyle(vm.clientName == nil ? Palette.ink3 : Palette.ink)
                            if let email = vm.clientEmail {
                                Text(email).font(.ui(12.5)).foregroundStyle(Palette.ink3)
                            }
                        }
                        Spacer(minLength: 0)
                        Icon(name: "chevR", size: 14, color: Palette.ink3)
                    }
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .disabled(vm.status != "draft")
            .accessibilityIdentifier(AccessibilityID.invoiceEditorClient)
        }
    }

    @ViewBuilder private func clientInitials(_ name: String?) -> some View {
        if let initials = initials(from: name) {
            RoundedRectangle(cornerRadius: 13, style: .continuous).fill(accent.soft).frame(width: 42, height: 42)
                .overlay(Text(initials).font(.ui(15, .bold)).foregroundStyle(accent.base))
        } else {
            IconCircle(name: "building", tint: accent.base, soft: accent.soft, size: 42, iconSize: 19)
        }
    }

    private func initials(from name: String?) -> String? {
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? nil : letters.uppercased()
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text.uppercased()).font(.ui(12.5, .bold)).foregroundStyle(Palette.ink3).kerning(0.3).padding(.bottom, 10)
    }

    @ViewBuilder private func lineItemsSection(_ vm: InvoiceEditorViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Line items").font(.ui(12.5, .bold)).foregroundStyle(Palette.ink3).kerning(0.3)
                Spacer()
                if vm.status == "draft" {
                    Button { vm.addLine() } label: {
                        HStack(spacing: 4) {
                            Icon(name: "plus", size: 14, color: accent.base, lineWidth: 2)
                            Text("Add").font(.ui(13, .bold)).foregroundStyle(accent.base)
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AccessibilityID.invoiceEditorAddLine)
                }
            }
            if vm.status == "draft" {
                Button("Saved items") { showCatalogPicker = true }
                    .font(.ui(13, .bold)).foregroundStyle(accent.base)
            }
            Card(padding: 14) {
                if vm.lineItems.isEmpty {
                    HStack { Text("No line items yet").font(.ui(13.5)).foregroundStyle(Palette.ink3); Spacer(minLength: 0) }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(vm.lineItems.enumerated()), id: \.element.id) { idx, line in
                            if idx > 0 { Divider().overlay(Palette.line2).padding(.vertical, 12) }
                            lineRow(vm, line).accessibilityIdentifier(AccessibilityID.invoiceLineRowPrefix + line.id)
                        }
                    }
                }
            }
        }
    }

    private func lineRow(_ vm: InvoiceEditorViewModel, _ line: InvoiceLineItem) -> some View {
        let editable = vm.status == "draft"
        return VStack(spacing: 8) {
            TextField("Unit (optional)", text: Binding(
                get: { line.unitLabel ?? "" }, set: { line.unitLabel = $0.isEmpty ? nil : $0 }))
                .font(.ui(12.5)).disabled(!editable)
            HStack(spacing: 8) {
                TextField("Description", text: Binding(get: { line.itemDescription }, set: { line.itemDescription = $0 }), axis: .vertical)
                    .lineLimit(2...5)
                    .font(.ui(14.5, .semibold)).disabled(!editable)
                Text(fmt(line.lineTotalCents)).font(.ui(14.5, .bold)).foregroundStyle(Palette.ink).monospacedDigit()
                if editable {
                    Button { vm.removeLine(line) } label: {
                        Icon(name: "close", size: 15, color: Palette.ink3).frame(width: 24, height: 24).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                TextField("Qty", text: Binding(get: { String(line.quantity) },
                    set: { line.quantity = max(1, Int($0.filter(\.isNumber)) ?? 1) }))
                    .keyboardType(.numberPad).disabled(!editable)
                    .padding(8).frame(width: 64).background(Palette.cream, in: RoundedRectangle(cornerRadius: 10))
                Text("×").font(.ui(13)).foregroundStyle(Palette.ink3)
                TextField("Unit $", text: Binding(get: { String(line.unitPriceCents / 100) },
                    set: { line.unitPriceCents = (Int($0.filter(\.isNumber)) ?? 0) * 100 }))
                    .keyboardType(.numberPad).disabled(!editable)
                    .padding(8).background(Palette.cream, in: RoundedRectangle(cornerRadius: 10))
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder private func dueDateSection(_ vm: InvoiceEditorViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            groupLabel("Due date")
            Card(padding: 14) {
                HStack {
                    Icon(name: "calendar", size: 15, color: Palette.ink3)
                    if vm.status == "draft" {
                        DatePicker("", selection: dueDateBinding(vm), displayedComponents: .date)
                            .labelsHidden()
                            .accessibilityIdentifier(AccessibilityID.invoiceEditorDueDate)
                    } else {
                        Text(fmtDate(vm.dueDate)).font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Bridge the ISO "YYYY-MM-DD" dueDate to a `Date` for the picker (UTC formatter).
    private func dueDateBinding(_ vm: InvoiceEditorViewModel) -> Binding<Date> {
        Binding(
            get: { ExportDateFormatter.shared.date(from: vm.dueDate) ?? Date() },
            set: { vm.setDueDate(ExportDateFormatter.shared.string(from: $0)) })
    }

    private func totalsCard(_ vm: InvoiceEditorViewModel) -> some View {
        let t = vm.totals
        let inclusive = vm.gstEnabled && vm.gstInclusive
        let editable = vm.status == "draft"
        return Card(padding: 16) {
            VStack(spacing: 12) {
                totalRow(inclusive ? "Subtotal (ex GST)" : "Subtotal", fmt(t.subtotal))
                Divider().overlay(Palette.line2)
                HStack {
                    Text(inclusive ? "GST (\(vm.gstRatePercentText)%) included" : "GST (\(vm.gstRatePercentText)%)").font(.ui(13.5)).foregroundStyle(Palette.ink2)
                    Spacer()
                    if vm.gstEnabled { Text(fmt(t.gst)).font(.ui(14, .semibold)).foregroundStyle(Palette.ink).monospacedDigit() }
                    Toggle("", isOn: Binding(get: { vm.gstEnabled },
                        set: { on in withAnimation(.easeInOut(duration: 0.2)) { vm.gstEnabled = on } }))
                        .labelsHidden().tint(Palette.income).scaleEffect(0.85).disabled(!editable)
                        .accessibilityIdentifier(AccessibilityID.invoiceEditorGst)
                }
                if vm.gstEnabled {
                    Divider().overlay(Palette.line2)
                    Toggle(isOn: Binding(get: { vm.gstInclusive }, set: { vm.gstInclusive = $0 })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(vm.taxLabel) inclusive").font(.ui(13.5, .semibold)).foregroundStyle(Palette.ink)
                            Text("Line prices already include \(vm.taxLabel)").font(.ui(11.5)).foregroundStyle(Palette.ink3)
                        }
                    }
                    .tint(Palette.income).disabled(!editable)
                    .accessibilityIdentifier(AccessibilityID.invoiceEditorGstInclusive)
                }
                Divider().overlay(Palette.line2)
                HStack {
                    Text("Total").font(.ui(15.5, .bold)).foregroundStyle(Palette.ink)
                    Spacer()
                    Text(fmt(t.total)).font(.ui(22, .bold)).foregroundStyle(accent.base).monospacedDigit()
                }
            }
        }
    }

    private func totalRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.ui(13.5)).foregroundStyle(Palette.ink2)
            Spacer()
            Text(value).font(.ui(14, .semibold)).foregroundStyle(Palette.ink).monospacedDigit()
        }
    }

    @ViewBuilder private func actionBar(_ vm: InvoiceEditorViewModel) -> some View {
        VStack(spacing: 8) {
            if let err = vm.errorMessage { Text(err).font(.ui(12.5)).foregroundStyle(Palette.alert) }
            HStack(spacing: 12) {
                // PDF — GENERATE (rebuild) the invoice PDF on demand, then open the share sheet.
                // Always enabled (builds a fresh PDF) rather than only opening a prior one.
                Button {
                    Task { if let url = await vm.generatePdf(api: api) { openURL(url) } }
                } label: { iconButton("doc", busy: vm.isGeneratingPdf) }
                    .buttonStyle(.plain).disabled(vm.isGeneratingPdf)
                    .accessibilityIdentifier(AccessibilityID.invoiceEditorPdf)

                if vm.status == "draft" {
                    primaryButton(title: vm.isIssuing ? "Issuing…" : "Issue invoice",
                                  icon: "check", busy: vm.isIssuing, enabled: vm.canIssue,
                                  a11y: AccessibilityID.invoiceEditorIssue) {
                        Task { _ = await vm.issue(api: api) }
                    }
                } else {
                    // Issued: PDF generate (above, left) + Record payment (secondary) + Send (primary).
                    Button { showRecordPayment = true } label: { iconButton("plus") }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(AccessibilityID.invoiceEditorRecordPayment)
                    // With a client email the primary action EMAILS the invoice; without one
                    // there's nobody to email, so it falls back to GENERATING a shareable PDF.
                    primaryButton(
                        title: vm.canEmail
                            ? (vm.isSending ? "Sending…" : "Send invoice")
                            : (vm.isGeneratingPdf ? "Saving…" : "Save PDF"),
                        icon: "share",
                        busy: vm.canEmail ? vm.isSending : vm.isGeneratingPdf,
                        enabled: !(vm.canEmail ? vm.isSending : vm.isGeneratingPdf),
                        a11y: AccessibilityID.invoiceEditorSend
                    ) {
                        Task {
                            // Routed through the VM so failures surface via vm.errorMessage.
                            if vm.canEmail {
                                // EMAIL the invoice → confirm with the success overlay. Do NOT pop
                                // the PDF share sheet (that made a successful send look like a PDF
                                // action). The overlay offers "View PDF" only if the email failed.
                                if await vm.send(api: api) {
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { sent = true }
                                }
                            } else if let url = await vm.generatePdf(api: api) {
                                openURL(url)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 26)
        .background(LinearGradient(colors: [Palette.cream.opacity(0), Palette.cream], startPoint: .top, endPoint: .bottom))
    }

    private func iconButton(_ name: String, busy: Bool = false) -> some View {
        Group {
            if busy { ProgressView().tint(Palette.ink2) }
            else { Icon(name: name, size: 22, color: Palette.ink2) }
        }
        .frame(width: 56, height: 56)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
        .contentShape(Rectangle())
    }

    private func primaryButton(title: String, icon: String, busy: Bool, enabled: Bool,
                               a11y: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().tint(.white) } else { Icon(name: icon, size: 18, color: .white, lineWidth: 2) }
                Text(title).font(.ui(16, .semibold)).foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(accent.base, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: accent.base.opacity(0.45), radius: 12, x: 0, y: 12)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled || busy).accessibilityIdentifier(a11y)
    }

    /// Post-send confirmation (mirrors QuoteEditorView): "Invoice sent!" when the email went
    /// out, or "Invoice ready!" + a "View PDF" share if the email failed. "Done" closes the editor.
    private func successOverlay(_ vm: InvoiceEditorViewModel) -> some View {
        ZStack {
            Palette.cream.opacity(0.97).ignoresSafeArea()
            VStack(spacing: 14) {
                ZStack {
                    Circle().fill(Palette.income).frame(width: 92, height: 92)
                    Icon(name: "check", size: 40, color: .white, lineWidth: 3)
                }
                .shadow(color: Palette.income.opacity(0.4), radius: 16, x: 0, y: 12)
                Text(vm.emailed ? "Invoice sent!" : "Invoice ready!")
                    .font(.display(23, .bold)).foregroundStyle(Palette.ink)
                Text("\(vm.displayNumber) · \(fmt(vm.totals.total))").font(.ui(14)).foregroundStyle(Palette.ink2)
                if !vm.emailed, let url = vm.pdfUrl {
                    Button { openURL(url) } label: {
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

    private func openURL(_ url: String) {
        let full = url.hasPrefix("http") ? url : "\(BackendConfig.configuredBaseURL.absoluteString)\(url)"
        shareURL = URL(string: full)
    }

    private struct ShareItem: Identifiable { let id = UUID(); let url: URL }
    private var shareItem: Binding<ShareItem?> {
        Binding(get: { shareURL.map { ShareItem(url: $0) } }, set: { if $0 == nil { shareURL = nil } })
    }
}

/// UIActivityViewController bridge for the invoice PDF share.
private struct InvoiceActivityView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
