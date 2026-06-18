import SwiftUI
import SwiftData
import UIKit

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
    @State private var items: [ItemDraft] = []
    @State private var originalItemIds: Set<String> = []
    /// Once the user types into the amount field (or a saved total is loaded), the
    /// amount stops auto-tracking the items sum — it's their authoritative override.
    @State private var amountManuallyEdited = false
    /// Overlay-presented screens don't get SwiftUI's automatic ScrollView keyboard
    /// avoidance, so this screen handles it itself: hide the save bar, reserve bottom
    /// room equal to the keyboard, and scroll the focused item above the keyboard.
    @State private var keyboardVisible = false
    @State private var keyboardHeight: CGFloat = 0
    @FocusState private var focusedField: ManualItemField?

    /// Identifies the focusable lower fields so the focused one can be scrolled clear of
    /// the keyboard (the merchant/date rows sit high enough that they never need it).
    private enum ManualItemField: Hashable {
        case note
        case name(String)   // ItemDraft.id
        case price(String)  // ItemDraft.id
        /// The `.id(...)` of the row to scroll into view for this field.
        var scrollId: String {
            switch self {
            case .note: return "row-note"
            case .name(let id), .price(let id): return "row-\(id)"
            }
        }
    }

    /// Income forces the green income tint; expenses use the active accent.
    private var tint: Color { isIncome ? Palette.income : accent.base }

    private var amountCents: Int {
        let cleaned = amount.replacingOccurrences(of: ",", with: "")
        let value = Decimal(string: cleaned) ?? 0
        let cents = NSDecimalNumber(decimal: value * 100).intValue
        return isIncome ? abs(cents) : -abs(cents)
    }
    private var itemsTotalCents: Int { ManualItemsMapper.totalCents(items) }
    private var hasIncompleteItem: Bool { ManualItemsMapper.hasIncompleteRow(items) }
    private var canSave: Bool {
        amountCents != 0 && !merchant.trimmingCharacters(in: .whitespaces).isEmpty && !hasIncompleteItem
    }

    /// The amount string from a cents total (2-dp, "." separator so it round-trips
    /// with `amountCents`'s `Decimal(string:)` parse, locale-independently); "" when
    /// zero so the `0.00` placeholder shows rather than a literal "0.00".
    private func amountString(fromCents cents: Int) -> String {
        cents == 0 ? "" : String(format: "%d.%02d", cents / 100, cents % 100)
    }
    /// Typing in the amount field marks it as a manual override (see `amountManuallyEdited`);
    /// auto-fill writes to `amount` directly and so never trips this.
    private var amountBinding: Binding<String> {
        Binding(get: { amount }, set: { amount = $0; amountManuallyEdited = true })
    }
    private func currencyString(_ cents: Int) -> String {
        (Decimal(cents) / 100).formatted(.currency(code: "AUD"))
    }

    /// Categories shown as chips. Income locks to the single "income" category; expenses
    /// list every non-income category.
    private var chipKeys: [CategoryKey] {
        isIncome ? [.income] : CategoryKey.allCases.filter { $0 != .income }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Palette.cream.ignoresSafeArea()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        typeToggle
                        amountDisplay
                        categoryChips
                        fieldsCard
                        itemsCard
                    }
                    .padding(.horizontal, 18).padding(.top, 70)
                    // Reserve room equal to the keyboard so the last item can scroll
                    // clear of it (this screen is an overlay → no automatic avoidance).
                    .padding(.bottom, 120 + (keyboardVisible ? keyboardHeight : 0))
                }
                // We drive avoidance manually (below); stop SwiftUI from also insetting.
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .keyboardDismissButton()
                .onChange(of: items) { _, _ in
                    // Auto-fill the amount from the items sum — unless the user has
                    // taken the amount over (then their value stands).
                    guard !amountManuallyEdited else { return }
                    amount = amountString(fromCents: itemsTotalCents)
                }
                .onChange(of: focusedField) { _, _ in scrollToFocusedItem(proxy) }
                .onChange(of: keyboardHeight) { _, _ in scrollToFocusedItem(proxy) }
            }
            header
            // Hide the save bar while editing so it can't cover the field that scrolls
            // up to the keyboard; it returns when the keyboard dismisses.
            saveBar
                .opacity(keyboardVisible ? 0 : 1)
                .allowsHitTesting(!keyboardVisible)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.manualScreen)
        .task { loadIfEditing() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            let h = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.height ?? 0
            withAnimation(.easeOut(duration: 0.2)) { keyboardHeight = h; keyboardVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.2)) { keyboardVisible = false }
        }
    }

    /// Scroll the focused lower field to sit comfortably above the keyboard.
    private func scrollToFocusedItem(_ proxy: ScrollViewProxy) {
        guard keyboardVisible, let target = focusedField?.scrollId else { return }
        // Let the bottom-padding/layout change settle before scrolling.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(target, anchor: UnitPoint(x: 0.5, y: 0.28))
            }
        }
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

        // Load existing line items so they can be edited; the loaded amount is the
        // authoritative total, so don't let auto-fill clobber it.
        let existing = (try? context.fetch(FetchDescriptor<LineItem>(
            predicate: #Predicate { $0.transactionId == tid && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        items = existing.map { ItemDraft(id: $0.id, name: $0.name, priceText: amountString(fromCents: $0.priceCents)) }
        originalItemIds = Set(existing.map(\.id))
        amountManuallyEdited = true
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
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)
        // Cream scrim so content scrolling up under the header (when the keyboard
        // pushes it up) fades out instead of colliding with the title. Hit-testable
        // so a hidden toggle underneath can't be tapped through it.
        .background(
            LinearGradient(colors: [Palette.cream, Palette.cream, Palette.cream.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        )
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
                TextField("0.00", text: amountBinding)
                    .numeric(52)
                    .foregroundStyle(amountCents != 0 ? tint : Palette.ink3)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .fixedSize()
                    .accessibilityIdentifier(AccessibilityID.manualAmount)
            }
            // Offer to snap the overridden amount back to the items total.
            if amountManuallyEdited, itemsTotalCents > 0, itemsTotalCents != abs(amountCents) {
                Button {
                    amount = amountString(fromCents: itemsTotalCents)
                    amountManuallyEdited = false
                } label: {
                    Text("Use items total \(currencyString(itemsTotalCents))")
                        .font(.ui(12.5, .bold)).foregroundStyle(tint)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(tint.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.manualItemsUseTotal)
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
                .focused($focusedField, equals: .note)
        }
        .padding(.vertical, 14).padding(.horizontal, 14)
        .id("row-note")
    }

    // MARK: - Items

    /// Receipt-style line items. Collapses to a single "Add item" affordance when
    /// empty; each row is name + price with a remove control. The amount above
    /// auto-sums these (see `amountBinding` / `onChange(of: items)`).
    private var itemsCard: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                ForEach($items) { $item in
                    itemRow($item)
                }
                if !items.isEmpty {
                    Rectangle().fill(Palette.line2).frame(height: 1).padding(.leading, 52)
                }
                addItemRow
            }
        }
    }

    private func itemRow(_ item: Binding<ItemDraft>) -> some View {
        let rowId = item.wrappedValue.id
        let index = items.firstIndex { $0.id == rowId } ?? 0
        return VStack(spacing: 0) {
            if index > 0 {
                Rectangle().fill(Palette.line2).frame(height: 1).padding(.leading, 52)
            }
            HStack(spacing: 10) {
                Icon(name: "tag", size: 18, color: Palette.ink3).frame(width: 28)
                TextField("Item name", text: item.name)
                    .font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
                    .focused($focusedField, equals: .name(rowId))
                    .accessibilityIdentifier("\(AccessibilityID.manualItemNamePrefix)\(index)")
                Text("$").font(.ui(14, .semibold)).foregroundStyle(Palette.ink3)
                TextField("0.00", text: item.priceText)
                    .font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 66)
                    .focused($focusedField, equals: .price(rowId))
                    .accessibilityIdentifier("\(AccessibilityID.manualItemPricePrefix)\(index)")
                Button { items.removeAll { $0.id == rowId } } label: {
                    Icon(name: "close", size: 13, color: Palette.ink3)
                        .frame(width: 26, height: 26)
                        .background(Palette.cream, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(AccessibilityID.manualItemRemovePrefix)\(index)")
            }
            .padding(.vertical, 9).padding(.horizontal, 14)
        }
        .id("row-\(rowId)")
    }

    private var addItemRow: some View {
        Button {
            let draft = ItemDraft()
            items.append(draft)
            // Move focus straight to the new row's name field (after it renders) so the
            // keyboard comes up with the cursor ready — no extra tap needed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focusedField = .name(draft.id)
            }
        } label: {
            HStack(spacing: 10) {
                Icon(name: "plus", size: 17, color: tint).frame(width: 28)
                Text(items.isEmpty ? "Add item" : "Add another item")
                    .font(.ui(15, .semibold)).foregroundStyle(tint)
                Spacer()
            }
            .padding(.vertical, 14).padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.manualItemsAdd)
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

        let txnId: String
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
            txnId = txn.id
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
            txnId = txn.id
        }
        // Persist the line items (insert/update/soft-delete) against this transaction.
        originalItemIds = ManualItemsReconciler.reconcile(
            drafts: items, originalIds: originalItemIds, txnId: txnId,
            userId: userId, context: context, sync: sync)
        onClose()
    }
}
