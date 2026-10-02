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
    /// Routes to the invoice editor after a convert (the new/existing invoice id). (spec §4.2)
    let onConvert: (String) -> Void
    /// Called after "Save Draft" persists the quote — routes to the Quotes list so the user lands
    /// on the saved draft. The editor and the list are sibling overlays, so a plain dismiss would
    /// land on the tab root, not the list.
    let onSavedDraft: () -> Void
    var showsRepeatReview = false

    @Environment(\.accent) private var accent
    @State private var vm: QuoteEditorViewModel?
    @State private var showClientPicker = false
    @State private var showCatalogPicker = false
    @State private var sent = false
    @State private var shareURL: URL?
    @State private var shareFileURL: URL?
    @State private var renderer = QuotePdfRenderer()
    /// Moves the keyboard to a line item's Description field (by line id) — set when "+ Add"
    /// inserts a new row so the user can start typing the description immediately.
    @FocusState private var focusedLineId: String?
    /// Hides the bottom send bar while the keyboard is up — it otherwise floats over the
    /// totals/content (`.ignoresSafeArea(.keyboard)` can't pin a ZStack-aligned child).
    @State private var keyboard = KeyboardObserver()

    var body: some View {
        ZStack(alignment: .bottom) {
            Palette.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if let vm { content(vm) } else { Color.clear }
            }
            // Pin the send bar to the bottom (behind the keyboard) instead of letting
            // it ride up and collide with the keyboard accessory bar while editing.
            // Hide the send bar while the keyboard is up so it doesn't float over the content.
            if let vm, !keyboard.isVisible { sendBar(vm).ignoresSafeArea(.keyboard, edges: .bottom) }
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
                                  onPick: { selection in
                                      vm.setClient(selection)
                                      showClientPicker = false
                                  },
                                  onClose: { showClientPicker = false })
                    .environment(\.accent, accent)
            }
        }
        .sheet(item: shareItem) { item in QuoteActivityView(url: item.url) }
        .sheet(item: shareFileItem) { item in QuoteActivityView(url: item.url) }
    }

    /// Sub-page chrome: close button | centered title | trailing quote number.
    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                Icon(name: "close", size: 18, color: Palette.ink2)
                    .frame(width: 40, height: 40)
                    .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .strokeBorder(Palette.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.logbookClose)
            .accessibilityLabel("Close")
            Text(quoteId == nil ? "New quote" : "Quote").font(.ui(16, .bold)).foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity).lineLimit(1)
            // Trailing slot: a "Save Draft" button while the quote is still a draft — persists it
            // (so it can be re-opened from the Quotes list) then dismisses; once sent it shows the
            // server-minted quote number instead.
            if vm == nil || vm?.statusValue == .draft {
                Button {
                    if vm?.saveDraft() == true { onSavedDraft() }
                } label: {
                    Text("Save Draft").font(.ui(12.5, .bold))
                        .foregroundStyle((vm?.canSaveDraft ?? false) ? accent.base : Palette.ink3)
                        .lineLimit(1).frame(minWidth: 40, alignment: .trailing)
                }
                .buttonStyle(.plain)
                .disabled(!(vm?.canSaveDraft ?? false))
                .accessibilityIdentifier(AccessibilityID.quoteSaveDraft)
            } else {
                Text(vm?.displayNumber ?? "Draft").font(.ui(12.5, .bold)).foregroundStyle(Palette.ink3)
                    .lineLimit(1).frame(minWidth: 40, alignment: .trailing)
            }
        }
        .padding(.top, 12).padding(.horizontal, 18).padding(.bottom, 12)
    }

    @ViewBuilder private func content(_ vm: QuoteEditorViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if showsRepeatReview { Text("Review prices and dates before sending.").font(.ui(13, .semibold)).foregroundStyle(Palette.ink2).accessibilityIdentifier(AccessibilityID.clientRepeatReview) }
                billToSection(vm)
                lineItemsSection(vm)
                totalsCard(vm)
                businessDetailsSection(vm)
                infoNote
            }
            .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 120)
        }
        // The number pad has no return key, and text fields share the same bar:
        // a responder-chain dismiss button works for whichever field is focused.
        .keyboardDismissButton()
    }

    /// Read-only preview of the business header + payment details that appear on the
    /// hosted quote (edited in Tax & GST settings). Each line/block shown only when set.
    @ViewBuilder private func businessDetailsSection(_ vm: QuoteEditorViewModel) -> some View {
        if vm.hasBusinessContact || vm.bankDetails != nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("On this quote").font(.ui(13, .bold)).foregroundStyle(Palette.ink3)
                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        if vm.hasBusinessContact {
                            VStack(alignment: .leading, spacing: 3) {
                                if let name = vm.businessName {
                                    Text(name).font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                                }
                                detailLine("ABN", vm.businessAbn)
                                detailLine(nil, vm.businessEmail)
                                detailLine(nil, vm.businessPhone)
                                detailLine(nil, vm.businessWebsite)
                                detailLine(nil, vm.businessAddress)
                            }
                        }
                        if let bank = vm.bankDetails {
                            if vm.hasBusinessContact { Divider().overlay(Palette.line2) }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Payment details").font(.ui(12, .bold)).foregroundStyle(Palette.ink3)
                                Text(bank).font(.ui(13.5)).foregroundStyle(Palette.ink2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func detailLine(_ label: String?, _ value: String?) -> some View {
        if let value {
            Text(label != nil ? "\(label!): \(value)" : value)
                .font(.ui(13)).foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Paper-2 info note with a lock glyph (design ref: "Valid for 28 days…").
    private var infoNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Icon(name: "lock", size: 15, color: Palette.ink3)
            Text("Valid for 28 days. Accepted quotes convert straight into an invoice.")
                .font(.ui(12.5)).foregroundStyle(Palette.ink2)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Palette.paper2, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
    }

    @ViewBuilder private func billToSection(_ vm: QuoteEditorViewModel) -> some View {
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
                            if let mobile = vm.clientMobile, !mobile.isEmpty {
                                Text(mobile).font(.ui(12.5)).foregroundStyle(Palette.ink3)
                            }
                            if let address = vm.clientAddress, !address.isEmpty {
                                Text(address).font(.ui(12.5)).foregroundStyle(Palette.ink3).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                        Icon(name: "chevR", size: 14, color: Palette.ink3)
                    }
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.quoteEditorClient)
        }
    }

    /// 42×42 r13 accent-soft tile: initials when a client is chosen, else a building glyph.
    @ViewBuilder private func clientInitials(_ name: String?) -> some View {
        if let initials = initials(from: name) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(accent.soft)
                .frame(width: 42, height: 42)
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

    /// Uppercase group label (12.5/700 ink-3, tracking 0.3).
    private func groupLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.ui(12.5, .bold)).foregroundStyle(Palette.ink3).kerning(0.3)
            .padding(.bottom, 10)
    }

    @ViewBuilder private func lineItemsSection(_ vm: QuoteEditorViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Label row: "Line items" + trailing "+ Add" accent button.
            HStack {
                Text("Line items").font(.ui(12.5, .bold)).foregroundStyle(Palette.ink3).kerning(0.3)
                Spacer()
                Button {
                    guard let id = vm.addLine() else { return }
                    // Defer one runloop tick so the freshly-inserted row's TextField is in the
                    // hierarchy before we move focus to it (focusing a not-yet-installed field no-ops).
                    DispatchQueue.main.async { focusedLineId = id }
                } label: {
                    HStack(spacing: 4) {
                        Icon(name: "plus", size: 14, color: accent.base, lineWidth: 2)
                        Text("Add").font(.ui(13, .bold)).foregroundStyle(accent.base)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.quoteEditorAddLine)
            }
            if vm.status == "draft" {
                Button("Saved items") { showCatalogPicker = true }
                    .font(.ui(13, .bold)).foregroundStyle(accent.base)
            }
            Card(padding: 14) {
                if vm.lineItems.isEmpty {
                    HStack {
                        Text("No line items yet").font(.ui(13.5)).foregroundStyle(Palette.ink3)
                        Spacer(minLength: 0)
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(vm.lineItems.enumerated()), id: \.element.id) { idx, line in
                            if idx > 0 { Divider().overlay(Palette.line2).padding(.vertical, 12) }
                            lineRow(vm, line)
                                .accessibilityIdentifier(AccessibilityID.quoteLineRowPrefix + line.id)
                        }
                    }
                }
            }
        }
    }

    private func lineRow(_ vm: QuoteEditorViewModel, _ line: QuoteLineItem) -> some View {
        VStack(spacing: 8) {
            TextField("Unit (optional)", text: Binding(
                get: { line.unitLabel ?? "" }, set: { line.unitLabel = $0.isEmpty ? nil : $0 }))
                .font(.ui(12.5))
            HStack(alignment: .top, spacing: 8) {
                TextField("Description", text: Binding(
                    get: { line.itemDescription }, set: { line.itemDescription = $0 }),
                    axis: .vertical)
                    .focused($focusedLineId, equals: line.id)
                    .lineLimit(1...6)
                    .font(.ui(14.5, .semibold))
                Text(fmt(line.lineTotalCents)).font(.ui(14.5, .bold)).foregroundStyle(Palette.ink).monospacedDigit()
                Button { vm.removeLine(line) } label: {
                    Icon(name: "close", size: 15, color: Palette.ink3)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                TextField("Qty", text: Binding(
                    get: { String(line.quantity) },
                    set: { line.quantity = max(1, Int($0.filter(\.isNumber)) ?? 1) }))
                    .keyboardType(.numberPad)
                    .padding(8).frame(width: 64).background(Palette.cream, in: RoundedRectangle(cornerRadius: 10))
                Text("×").font(.ui(13)).foregroundStyle(Palette.ink3)
                Text("$").font(.ui(13)).foregroundStyle(Palette.ink3)
                LinePriceField(cents: Binding(
                    get: { line.unitPriceCents },
                    set: { line.unitPriceCents = $0 }))
                    .padding(8).background(Palette.cream, in: RoundedRectangle(cornerRadius: 10))
                Spacer(minLength: 0)
            }
        }
    }

    private func totalsCard(_ vm: QuoteEditorViewModel) -> some View {
        let t = vm.totals
        // Inclusive mode relabels the ledger: the subtotal is the ex-GST base and the
        // GST line is the embedded portion (total is unchanged from the entered sum).
        let inclusive = vm.gstEnabled && vm.gstInclusive
        return Card(padding: 16) {
            VStack(spacing: 12) {
                totalRow(inclusive ? "Subtotal (ex GST)" : "Subtotal", fmt(t.subtotal))
                Divider().overlay(Palette.line2)

                // "GST (10%)" row carries a compact income-track toggle. Kept as a real
                // Toggle (XCUI queries app.switches[quoteEditorGst]); .labelsHidden() +
                // income tint = the design's 42×26 income pill.
                HStack {
                    Text(inclusive ? "GST (\(vm.gstRatePercentText)%) included" : "GST (\(vm.gstRatePercentText)%)")
                        .font(.ui(13.5)).foregroundStyle(Palette.ink2)
                    Spacer()
                    if vm.gstEnabled {
                        Text(fmt(t.gst)).font(.ui(14, .semibold)).foregroundStyle(Palette.ink).monospacedDigit()
                    }
                    Toggle("", isOn: Binding(
                        get: { vm.gstEnabled },
                        set: { on in withAnimation(.easeInOut(duration: 0.2)) { vm.gstEnabled = on } }))
                        .labelsHidden()
                        .tint(Palette.income)
                        .scaleEffect(0.85)
                        .accessibilityIdentifier(AccessibilityID.quoteEditorGst)
                }

                // GST-inclusive mode only makes sense once GST is on.
                if vm.gstEnabled {
                    Divider().overlay(Palette.line2)
                    Toggle(isOn: Binding(get: { vm.gstInclusive }, set: { vm.gstInclusive = $0 })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(vm.taxLabel) inclusive").font(.ui(13.5, .semibold)).foregroundStyle(Palette.ink)
                            Text("Line prices already include \(vm.taxLabel)").font(.ui(11.5)).foregroundStyle(Palette.ink3)
                        }
                    }
                    .tint(Palette.income)
                    .accessibilityIdentifier(AccessibilityID.quoteEditorGstInclusive)
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

    @ViewBuilder private func sendBar(_ vm: QuoteEditorViewModel) -> some View {
        VStack(spacing: 8) {
            if let err = vm.errorMessage {
                Text(err).font(.ui(12.5)).foregroundStyle(Palette.alert)
            }
            if vm.canConvert {
                Button {
                    if let invId = vm.convertToInvoice() { onConvert(invId) }
                } label: {
                    HStack(spacing: 6) {
                        Icon(name: "receipt", size: 15, color: accent.base, lineWidth: 2)
                        Text(vm.invoiceId == nil ? "Convert to invoice" : "Open invoice")
                            .font(.ui(14, .semibold)).foregroundStyle(accent.base)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(accent.soft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.quoteEditorConvert)
            }
            HStack(spacing: 12) {
                // Share menu (56×56 r18 paper): enabled whenever the quote is valid (client
                // + ≥1 line). Offers "Share link" (the hosted HTML quote URL) and "Generate
                // PDF" (render that link in a hidden WKWebView → PDF file). (spec §4)
                Menu {
                    Button {
                        Task {
                            if let url = await vm.shareLink(api: api), let u = URL(string: absolute(url)) {
                                shareURL = u
                            }
                        }
                    } label: { Label("Share link", systemImage: "link") }
                    .accessibilityIdentifier(AccessibilityID.quoteEditorShareLink)

                    Button {
                        Task {
                            if let file = await vm.generatePdf(api: api, renderer: renderer) {
                                shareFileURL = file
                            }
                        }
                    } label: { Label("Generate PDF", systemImage: "doc") }
                    .accessibilityIdentifier(AccessibilityID.quoteEditorGeneratePdf)
                } label: {
                    Icon(name: "doc", size: 22, color: Palette.ink2)
                        .frame(width: 56, height: 56)
                        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Palette.line, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .disabled(!vm.canGeneratePdf || vm.isSending)
                .opacity(vm.canGeneratePdf ? 1 : 0.45)
                .accessibilityIdentifier(AccessibilityID.quoteEditorShareMenu)

                Button {
                    Task {
                        if await vm.send(api: api) {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { sent = true }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if vm.isSending { ProgressView().tint(.white) }
                        else { Icon(name: "share", size: 18, color: .white, lineWidth: 2) }
                        Text(vm.isSending ? "Sending…" : "Send quote").font(.ui(16, .semibold)).foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(accent.base, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: accent.base.opacity(0.45), radius: 12, x: 0, y: 12)
                    // Disabled = faded accent (house pattern: Onboarding Continue .5, Reports CTA .45),
                    // not an opaque grey swap.
                    .opacity(vm.canSend ? 1 : 0.45)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!vm.canSend || vm.isSending)
                .accessibilityIdentifier(AccessibilityID.quoteEditorSend)
            }
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 26)
        .background(
            LinearGradient(colors: [Palette.cream.opacity(0), Palette.cream],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private func successOverlay(_ vm: QuoteEditorViewModel) -> some View {
        ZStack {
            Palette.cream.opacity(0.97).ignoresSafeArea()
            VStack(spacing: 14) {
                ZStack {
                    Circle().fill(Palette.income).frame(width: 92, height: 92)
                    Icon(name: "check", size: 40, color: .white, lineWidth: 3)
                }
                .shadow(color: Palette.income.opacity(0.4), radius: 16, x: 0, y: 12)
                Text(vm.emailed ? "Quote sent!" : "Quote ready!").font(.display(23, .bold)).foregroundStyle(Palette.ink)
                Text("\(vm.displayNumber) · \(fmt(vm.totals.total))").font(.ui(14)).foregroundStyle(Palette.ink2)
                if !vm.emailed {
                    Button {
                        Task {
                            if let url = await vm.shareLink(api: api), let u = URL(string: absolute(url)) {
                                shareURL = u
                            }
                        }
                    } label: {
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

    private func absolute(_ url: String) -> String {
        url.hasPrefix("http") ? url : "\(BackendConfig.configuredBaseURL.absoluteString)\(url)"
    }

    private struct ShareItem: Identifiable { let id = UUID(); let url: URL }
    private var shareItem: Binding<ShareItem?> {
        Binding(get: { shareURL.map { ShareItem(url: $0) } },
                set: { if $0 == nil { shareURL = nil } })
    }
    private var shareFileItem: Binding<ShareItem?> {
        Binding(get: { shareFileURL.map { ShareItem(url: $0) } },
                set: { if $0 == nil { shareFileURL = nil } })
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
