import SwiftUI
import SwiftData

/// Read-only detail page for one saved receipt: the scanned image, headline (merchant /
/// amount / date / category), a details card (GST, deductible, type, payment, source,
/// note), and line items. Presented as a sheet from the Activity tab / Home recents.
struct ReceiptDetailView: View {
    let context: ModelContext
    let transactionId: String
    let onClose: () -> Void
    @Environment(\.accent) private var accent
    @State private var vm: ReceiptDetailViewModel?

    var body: some View {
        ZStack(alignment: .top) {
            Palette.cream.ignoresSafeArea()
            ScrollView {
                if let vm, let row = vm.row, let txn = vm.txn {
                    VStack(spacing: 18) {
                        if let image = vm.image { imageCard(image) }
                        summary(row)
                        detailsCard(row, txn)
                        if !vm.lineItems.isEmpty { lineItemsCard(vm.lineItems, currency: txn.currency) }
                    }
                    .padding(.horizontal, 18).padding(.top, 64).padding(.bottom, 40)
                } else {
                    notFound.padding(.top, 140)
                }
            }
            topBar
        }
        .task { vm = ReceiptDetailViewModel(context: context, transactionId: transactionId) }
        .accessibilityIdentifier(AccessibilityID.receiptDetailScreen)
    }

    // MARK: - Sections

    private var topBar: some View {
        HStack {
            Text("Receipt").font(.ui(17, .bold)).foregroundStyle(Palette.ink)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Palette.ink2)
                    .frame(width: 32, height: 32).background(Palette.paper2, in: Circle())
            }
            .accessibilityIdentifier(AccessibilityID.receiptDetailClose)
        }
        .padding(.horizontal, 18).padding(.top, 14)
    }

    private func imageCard(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable().aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 340)
            .background(Palette.paper)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.line, lineWidth: 1))
    }

    private func summary(_ row: ReceiptRow) -> some View {
        let meta = row.category.flatMap { CATS[$0] }
        return VStack(spacing: 8) {
            Text(row.merchant).font(.ui(20, .bold)).foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
            Text(row.isIncome ? "+\(row.amountText)" : row.amountText)
                .font(.ui(30, .bold)).monospacedDigit()
                .foregroundStyle(row.isIncome ? Palette.income : Palette.ink)
            HStack(spacing: 8) {
                Text(row.dateText).font(.ui(13)).foregroundStyle(Palette.ink2)
                if let meta {
                    Text(meta.label).font(.ui(11.5, .bold)).foregroundStyle(meta.tint)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(meta.soft, in: Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func detailsCard(_ row: ReceiptRow, _ txn: Transaction) -> some View {
        var items: [(String, String)] = []
        items.append(("Category", row.category.flatMap { CATS[$0]?.label } ?? txn.catKey.capitalized))
        if let gst = txn.gstCents {
            items.append(("GST", txn.gstFree ? "GST-free"
                          : (Decimal(gst) / 100).formatted(.currency(code: txn.currency))))
        }
        if let pct = txn.deductiblePct { items.append(("Deductible", "\(pct)%")) }
        items.append(("Type", txn.mode == "business" ? "Business" : "Personal"))
        if let pm = txn.paymentMethod, !pm.isEmpty { items.append(("Payment", pm.capitalized)) }
        items.append(("Added", sourceLabel(txn.source)))
        if let note = txn.note, !note.isEmpty { items.append(("Note", note)) }

        return VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                if idx > 0 { Divider().overlay(Palette.line) }
                HStack(alignment: .top) {
                    Text(item.0).font(.ui(14)).foregroundStyle(Palette.ink2)
                    Spacer(minLength: 16)
                    Text(item.1).font(.ui(14, .semibold)).foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.vertical, 13)
            }
        }
        .padding(.horizontal, 16)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line, lineWidth: 1))
    }

    private func lineItemsCard(_ items: [LineItem], currency: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Items").font(.ui(12.5, .bold)).foregroundStyle(Palette.ink3)
                .padding(.top, 13).padding(.bottom, 6)
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                if idx > 0 { Divider().overlay(Palette.line) }
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
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line, lineWidth: 1))
    }

    private var notFound: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.questionmark").font(.system(size: 34)).foregroundStyle(Palette.ink3)
            Text("Receipt not found").font(.ui(16, .semibold)).foregroundStyle(Palette.ink)
        }
    }

    private func sourceLabel(_ source: String) -> String {
        switch source {
        case "scan": return "Scanned"
        case "email_in": return "Email-in"
        case "import": return "Imported"
        default: return "Manual"
        }
    }
}
