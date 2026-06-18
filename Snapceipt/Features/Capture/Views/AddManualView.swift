import SwiftUI
import SwiftData

/// Manual transaction entry — the design's "Add manually" flow, reached from the
/// Home quick-action. Saves a `source: "manual"` Transaction (no scan/image) scoped
/// to the active profile and enqueues it for sync, mirroring `CaptureViewModel.save`.
///
/// Layout matches `manual-page.jsx`: a segmented Expense/Income toggle, a big centered
/// live amount, a horizontal row of category chips, and a merchant + date card. The
/// custom keypad in the prototype is replaced by the system decimal keyboard (a custom
/// keypad is impractical here); everything else follows the design.
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

    /// Income forces the green income tint; expenses use the active accent.
    private var tint: Color { isIncome ? Palette.income : accent.base }

    private var amountCents: Int {
        let cleaned = amount.replacingOccurrences(of: ",", with: "")
        let value = Decimal(string: cleaned) ?? 0
        let cents = NSDecimalNumber(decimal: value * 100).intValue
        return isIncome ? abs(cents) : -abs(cents)
    }
    private var canSave: Bool { amountCents != 0 && !merchant.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Categories shown as chips. Income locks to the single "income" category; expenses
    /// list every non-income category.
    private var chipKeys: [CategoryKey] {
        isIncome ? [.income] : CategoryKey.allCases.filter { $0 != .income }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Palette.cream.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    typeToggle
                    amountDisplay
                    categoryChips
                    fieldsCard
                }
                .padding(.horizontal, 18).padding(.top, 70).padding(.bottom, 120)
            }
            .keyboardDismissButton()
            header
            saveBar
        }
        .accessibilityElement(children: .contain)
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
            .buttonStyle(.plain)
            Spacer()
            Text(editId == nil ? "Add manually" : "Edit transaction")
                .font(.ui(16, .bold)).foregroundStyle(Palette.ink)
            Spacer()
            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 18).padding(.top, 14)
    }

    // MARK: - Type toggle

    private var typeToggle: some View {
        Segmented(
            options: [SegmentOption(id: "expense", label: "Expense"),
                      SegmentOption(id: "income", label: "Income")],
            selection: Binding(
                get: { isIncome ? "income" : "expense" },
                set: { newValue in
                    let wasIncome = isIncome
                    isIncome = (newValue == "income")
                    if isIncome {
                        category = .income
                    } else if wasIncome {
                        // Leaving income — restore a sensible expense default.
                        category = .meals
                    }
                }
            )
        )
    }

    // MARK: - Amount display

    private var amountDisplay: some View {
        VStack(spacing: 6) {
            Text(isIncome ? "Amount received" : "Amount spent")
                .font(.ui(12.5, .bold)).tracking(0.3).foregroundStyle(Palette.ink3)
            HStack(spacing: 2) {
                Text("$").font(.display(34, .bold)).foregroundStyle(amountCents != 0 ? tint : Palette.ink3)
                TextField("0.00", text: $amount)
                    .numeric(52)
                    .foregroundStyle(amountCents != 0 ? tint : Palette.ink3)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .fixedSize()
                    .accessibilityIdentifier(AccessibilityID.manualAmount)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    // MARK: - Category chips

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chipKeys, id: \.self) { key in
                    let meta = CATS[key]
                    Chip(title: meta?.label ?? key.rawValue.capitalized,
                         isActive: category == key,
                         iconName: meta?.iconName) {
                        category = key
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        // Income locks to the single income chip — make the row read as informational.
        .disabled(isIncome)
    }

    // MARK: - Merchant + date card

    private var fieldsCard: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                merchantRow
                Rectangle().fill(Palette.line2).frame(height: 1).padding(.leading, 56)
                dateRow
                Rectangle().fill(Palette.line2).frame(height: 1).padding(.leading, 56)
                noteRow
            }
        }
    }

    private var merchantRow: some View {
        HStack(spacing: 12) {
            Icon(name: isIncome ? "wallet" : "tag", size: 19, color: Palette.ink3)
                .frame(width: 32)
            TextField(isIncome ? "Source (e.g. Invoice #1043)" : "Merchant (e.g. Officeworks)",
                      text: $merchant)
                .font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
                .accessibilityIdentifier(AccessibilityID.manualMerchant)
        }
        .padding(.vertical, 14).padding(.horizontal, 14)
    }

    private var dateRow: some View {
        HStack(spacing: 12) {
            Icon(name: "calendar", size: 19, color: Palette.ink3)
                .frame(width: 32)
            Text("Date").font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
            Spacer(minLength: 8)
            DatePicker("", selection: $date, displayedComponents: .date)
                .labelsHidden().tint(tint)
        }
        .padding(.vertical, 10).padding(.horizontal, 14)
    }

    private var noteRow: some View {
        HStack(spacing: 12) {
            Icon(name: "doc", size: 19, color: Palette.ink3)
                .frame(width: 32)
            TextField("Note (optional)", text: $note)
                .font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
        }
        .padding(.vertical, 14).padding(.horizontal, 14)
    }

    // MARK: - Save

    private var saveBar: some View {
        VStack {
            Spacer()
            Button(action: save) {
                HStack(spacing: 8) {
                    Icon(name: "check", size: 20, color: .white)
                    Text(isIncome ? "Save income" : "Save expense")
                        .font(.ui(16, .bold)).foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity).frame(height: 56)
                .background(canSave ? tint : Palette.line,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .foregroundStyle(canSave ? .white : Palette.ink3)
                .shadow(color: tint.opacity(canSave ? 0.4 : 0), radius: 12, x: 0, y: 10)
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
