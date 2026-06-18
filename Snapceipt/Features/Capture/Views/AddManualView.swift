import SwiftUI
import SwiftData

/// Manual transaction entry — the design's "Add manually" flow, reached from the
/// Home quick-action. Saves a `source: "manual"` Transaction (no scan/image) scoped
/// to the active profile and enqueues it for sync, mirroring `CaptureViewModel.save`.
struct AddManualView: View {
    let context: ModelContext
    let sync: any SyncEnqueuing
    let userId: String
    let profileId: String
    let isBusiness: Bool
    var editId: String? = nil
    let onClose: () -> Void

    @Environment(\.accent) private var accent
    @State private var isIncome = false
    @State private var amount = ""
    @State private var merchant = ""
    @State private var category: CategoryKey = .meals
    @State private var date = Date()
    @State private var note = ""

    private var amountCents: Int {
        let cleaned = amount.replacingOccurrences(of: ",", with: "")
        let value = Decimal(string: cleaned) ?? 0
        let cents = NSDecimalNumber(decimal: value * 100).intValue
        return isIncome ? abs(cents) : -abs(cents)
    }
    private var canSave: Bool { amountCents != 0 && !merchant.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        ZStack(alignment: .top) {
            Palette.cream.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    typeToggle
                    amountCard
                    fieldsCard
                }
                .padding(.horizontal, 18).padding(.top, 70).padding(.bottom, 120)
            }
            header
            saveBar
        }
        .accessibilityIdentifier(AccessibilityID.manualScreen)
        .task { loadIfEditing() }
    }

    /// Pre-fill the form when opened to edit an existing transaction.
    private func loadIfEditing() {
        guard let editId, merchant.isEmpty, amount.isEmpty else { return }
        let tid = editId
        guard let t = (try? context.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.id == tid })))?.first else { return }
        isIncome = t.amountCents > 0
        amount = (Decimal(abs(t.amountCents)) / 100).formatted(.number.precision(.fractionLength(2)).grouping(.never))
        merchant = t.merchant
        category = CategoryKey(rawValue: t.catKey) ?? .meals
        note = t.note ?? ""
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        if let d = f.date(from: t.txnDate) { date = d }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(action: onClose) {
                Icon(name: "close", size: 19, color: Palette.ink2)
                    .frame(width: 40, height: 40)
                    .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
            }
            Spacer()
            Text(editId == nil ? "Add manually" : "Edit transaction")
                .font(.ui(16, .bold)).foregroundStyle(Palette.ink)
            Spacer()
            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 18).padding(.top, 14)
    }

    // MARK: - Fields

    private var typeToggle: some View {
        Segmented(
            options: [SegmentOption(id: "expense", label: "Expense"),
                      SegmentOption(id: "income", label: "Income")],
            selection: Binding(
                get: { isIncome ? "income" : "expense" },
                set: { isIncome = ($0 == "income"); if isIncome { category = .income } }
            )
        )
    }

    private var amountCard: some View {
        VStack(spacing: 6) {
            Text(isIncome ? "Amount received" : "Amount spent")
                .font(.ui(13)).foregroundStyle(Palette.ink2)
            HStack(spacing: 2) {
                Text("$").font(.display(30, .bold)).foregroundStyle(Palette.ink3)
                TextField("0.00", text: $amount)
                    .font(.display(34, .bold)).foregroundStyle(isIncome ? Palette.income : Palette.ink)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .fixedSize()
                    .accessibilityIdentifier(AccessibilityID.manualAmount)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.line2, lineWidth: 1))
        .cardShadow()
    }

    private var fieldsCard: some View {
        VStack(spacing: 0) {
            field(label: "Merchant") {
                TextField(isIncome ? "Source" : "Where", text: $merchant)
                    .font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier(AccessibilityID.manualMerchant)
            }
            Divider().overlay(Palette.line2)
            field(label: "Category") {
                Menu {
                    ForEach(CategoryKey.allCases, id: \.self) { key in
                        Button(CATS[key]?.label ?? key.rawValue.capitalized) { category = key }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(CATS[category]?.label ?? category.rawValue.capitalized)
                            .font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
                        Icon(name: "chevD", size: 15, color: Palette.ink3)
                    }
                }
            }
            Divider().overlay(Palette.line2)
            field(label: "Date") {
                DatePicker("", selection: $date, displayedComponents: .date)
                    .labelsHidden().tint(accent.base)
            }
            Divider().overlay(Palette.line2)
            field(label: "Note") {
                TextField("Optional", text: $note)
                    .font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.horizontal, 16)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.line2, lineWidth: 1))
        .cardShadow()
    }

    private func field<Trailing: View>(label: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(label).font(.ui(14)).foregroundStyle(Palette.ink2)
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.vertical, 14)
    }

    // MARK: - Save

    private var saveBar: some View {
        VStack {
            Spacer()
            Button(action: save) {
                HStack(spacing: 8) {
                    Icon(name: "check", size: 20, color: .white)
                    Text("Save transaction").font(.ui(16, .bold)).foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity).frame(height: 56)
                .background(canSave ? accent.base : Palette.ink3,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: accent.base.opacity(canSave ? 0.4 : 0), radius: 12, x: 0, y: 10)
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            .accessibilityIdentifier(AccessibilityID.manualSave)
            .padding(.horizontal, 18).padding(.bottom, 20)
        }
        .background(
            LinearGradient(colors: [Palette.cream.opacity(0), Palette.cream],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 130).frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
        )
    }

    private func save() {
        guard canSave else { return }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let cleanMerchant = merchant.trimmingCharacters(in: .whitespaces)
        let cleanNote = note.isEmpty ? nil : note

        if let editId, let txn = (try? context.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.id == editId })))?.first {
            // Update the existing transaction in place.
            txn.merchant = cleanMerchant
            txn.catKey = category.rawValue
            txn.amountCents = amountCents
            txn.txnDate = f.string(from: date)
            txn.note = cleanNote
            txn.updatedAt = Epoch.nowMs()
            try? context.save()
            sync.enqueue(op: "upsert", entityType: .transaction, entity: txn)
        } else {
            let txn = Transaction(
                userId: userId,
                profileId: profileId,
                merchant: cleanMerchant,
                catKey: category.rawValue,
                amountCents: amountCents,
                txnDate: f.string(from: date),
                mode: isBusiness ? "business" : "personal",
                deductiblePct: isBusiness && !isIncome ? 100 : nil,
                isAi: false,
                note: cleanNote,
                source: "manual"
            )
            context.insert(txn)
            try? context.save()
            sync.enqueue(op: "upsert", entityType: .transaction, entity: txn)
        }
        onClose()
    }
}
