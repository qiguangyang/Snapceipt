import SwiftUI
import SwiftData

/// Read-only detail page for one saved receipt — the design's `TxnDetail`: a header
/// (back / "Transaction" / overflow), a category icon + merchant + large amount with
/// mode & AI chips, a details card, the scanned image, line items, and Edit / Delete
/// actions. Presented as a sheet from the Activity tab / Home recents.
struct ReceiptDetailView: View {
    let context: ModelContext
    let sync: any SyncEnqueuing
    let api: any APIClient
    let transactionId: String
    let onEdit: (String) -> Void
    let onClose: () -> Void
    @Environment(\.accent) private var accent
    @State private var vm: ReceiptDetailViewModel?
    @State private var confirmingDelete = false
    @State private var showImageViewer = false

    var body: some View {
        ZStack(alignment: .top) {
            Palette.cream.ignoresSafeArea()
            ScrollView {
                if let vm, let row = vm.row, let txn = vm.txn {
                    VStack(spacing: 16) {
                        summary(row, txn)
                        detailsCard(row, txn)
                        if let image = vm.image {
                            imageCard(image)
                                .contentShape(Rectangle())
                                .onTapGesture { showImageViewer = true }
                                .accessibilityIdentifier(AccessibilityID.receiptImageTap)
                        } else if vm.isLoadingImage {
                            Card(padding: 24) {
                                HStack { Spacer(); ProgressView(); Spacer() }
                            }
                        }
                        if !vm.lineItems.isEmpty { lineItemsCard(vm.lineItems, currency: txn.currency) }
                        actions
                    }
                    .padding(.horizontal, 18).padding(.top, 64).padding(.bottom, 40)
                } else {
                    notFound.padding(.top, 140)
                }
            }
            header
        }
        .task { vm = ReceiptDetailViewModel(context: context, transactionId: transactionId, api: api) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.receiptDetailScreen)
        .confirmationDialog("Delete this transaction?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteReceipt() }
            Button("Cancel", role: .cancel) {}
        }
        .fullScreenCover(isPresented: $showImageViewer) {
            if let image = vm?.image {
                ReceiptImageViewer(image: image) { showImageViewer = false }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            squareButton(icon: "arrowLeft", action: onClose)
                .accessibilityIdentifier(AccessibilityID.receiptDetailClose)
            Spacer()
            Text("Transaction").font(.ui(16, .bold)).foregroundStyle(Palette.ink)
            Spacer()
            squareButton(icon: "dots") { confirmingDelete = true }
        }
        .padding(.horizontal, 18).padding(.top, 14)
    }

    private func squareButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Icon(name: icon, size: 20, color: Palette.ink2)
                .frame(width: 40, height: 40)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sections

    private func summary(_ row: ReceiptRow, _ txn: Transaction) -> some View {
        let meta = row.category.flatMap { CATS[$0] }
        let business = txn.mode == "business"
        let modeAccent: AccentPalette = business ? .business : .personal
        return VStack(spacing: 12) {
            IconCircle(name: meta?.iconName ?? "receipt",
                       tint: meta?.tint ?? accent.base, soft: meta?.soft ?? accent.soft,
                       size: 62, iconSize: 30, filled: row.category == .income)
            Text(row.merchant).font(.ui(19, .bold)).foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
            Text(row.isIncome ? "+\(row.amountText)" : "−\(row.amountText)")
                .numeric(38).foregroundStyle(row.isIncome ? Palette.income : Palette.ink)
            HStack(spacing: 8) {
                Text(business ? "Business" : "Personal")
                    .font(.ui(12, .bold)).foregroundStyle(modeAccent.deep)
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(modeAccent.soft, in: Capsule())
                if txn.isAi {
                    HStack(spacing: 4) {
                        Icon(name: "sparkles", size: 12, color: accent.base, filled: true)
                        Text("AI sorted").font(.ui(12, .bold)).foregroundStyle(accent.base)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(Palette.paper, in: Capsule())
                    .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private func detailsCard(_ row: ReceiptRow, _ txn: Transaction) -> some View {
        var items: [(String, String, Color)] = []
        // Income is a transaction TYPE (amount direction), not a category — present it as such.
        // The green "+amount" already signals income; a "Category: Income" row read as a
        // confusing expense category (e.g. an invoice "categorised as income").
        if row.isIncome {
            items.append(("Type", "Income", Palette.income))
        } else {
            items.append(("Type", "Expense", Palette.ink))
            items.append(("Category", row.category.flatMap { CATS[$0]?.label } ?? txn.catKey.capitalized, Palette.ink))
        }
        items.append(("Date", Self.longDate(txn.txnDate), Palette.ink))
        if let pm = txn.paymentMethod, !pm.isEmpty { items.append(("Payment", pm.capitalized, Palette.ink)) }
        if let gst = txn.gstCents {
            items.append(("\(receiptTaxLabel(for: txn.currency)) included", txn.gstFree ? "GST-free"
                          : (Decimal(gst) / 100).formatted(.currency(code: txn.currency)), Palette.ink))
        }
        if let tax = txn.taxLabel, !tax.isEmpty { items.append(("Tax note", tax, Palette.ink)) }
        if !row.isIncome, let pct = txn.deductiblePct { items.append(("Deductible", "\(pct)%", Palette.income)) }
        if let note = txn.note, !note.isEmpty { items.append(("Note", note, Palette.ink)) }

        return VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                if idx > 0 { Divider().overlay(Palette.line2) }
                HStack(alignment: .top) {
                    Text(item.0).font(.ui(14)).foregroundStyle(Palette.ink2)
                    Spacer(minLength: 16)
                    Text(item.1).font(.ui(14.5, .bold)).foregroundStyle(item.2)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.vertical, 14)
            }
        }
        .padding(.horizontal, 16)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.line2, lineWidth: 1))
        .cardShadow()
    }

    private func imageCard(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable().aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 340)
            .background(Palette.paper)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.line2, lineWidth: 1))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .padding(7).background(.black.opacity(0.45), in: Circle())
                    .padding(10)
            }
    }

    private func lineItemsCard(_ items: [LineItem], currency: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Items").font(.ui(12.5, .bold)).foregroundStyle(Palette.ink3)
                .padding(.top, 13).padding(.bottom, 6)
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                if idx > 0 { Divider().overlay(Palette.line2) }
                HStack {
                    Text(item.quantity > 1 ? "\(item.name) ×\(item.quantity)" : item.name)
                        .font(.ui(14)).foregroundStyle(Palette.ink).lineLimit(1)
                    Spacer(minLength: 12)
                    Text((Decimal(item.priceCents) / 100).formatted(.currency(code: currency)))
                        .font(.ui(14, .semibold)).monospacedDigit().foregroundStyle(Palette.ink)
                }
                .padding(.vertical, 11)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 4)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.line2, lineWidth: 1))
        .cardShadow()
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button { onEdit(transactionId) } label: {
                actionLabel(icon: "pencil", title: "Edit", tint: Palette.ink)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.receiptDetailEdit)
            Button { confirmingDelete = true } label: {
                actionLabel(icon: "trash", title: "Delete", tint: Palette.alert)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.receiptDetailDelete)
        }
    }

    private func actionLabel(icon: String, title: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Icon(name: icon, size: 18, color: tint)
            Text(title).font(.ui(14.5, .bold)).foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity).frame(height: 50)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
    }

    private var notFound: some View {
        VStack(spacing: 10) {
            Icon(name: "doc", size: 34, color: Palette.ink3)
            Text("Receipt not found").font(.ui(16, .semibold)).foregroundStyle(Palette.ink)
        }
    }

    // MARK: - Actions

    private func deleteReceipt() {
        let tid = transactionId
        guard let txn = (try? context.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.id == tid })))?.first else { return }
        txn.deletedAt = Epoch.nowMs()
        txn.updatedAt = Epoch.nowMs()
        try? context.save()
        sync.enqueue(op: "delete", entityType: .transaction, entity: txn)
        onClose()
    }

    /// "Sat, 28 May 2026" (falls back to the raw key).
    static func longDate(_ key: String) -> String {
        guard let d = iso.date(from: key) else { return key }
        return display.string(from: d)
    }
    private static let iso: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let display: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE, d MMM yyyy"; return f
    }()
}
