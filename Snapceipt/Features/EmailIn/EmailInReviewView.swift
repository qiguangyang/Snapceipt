import SwiftUI
import SwiftData

/// Review + fix a single email_in transaction, then Save (flips failed->done).
struct EmailInReviewView: View {
    let vm: EmailInViewModel
    let transactionId: String
    let onClose: () -> Void
    @Environment(\.accent) private var accent

    @State private var merchant = ""
    @State private var amountText = ""
    @State private var txnDate = ""
    @State private var catKey = "office"
    @State private var loaded = false

    private let catKeys = ["meals", "groceries", "fuel", "software", "office", "home", "health", "travel", "income", "custom"]

    private var txn: Transaction? { vm.inbox.first { $0.id == transactionId } }

    /// Save is only allowed once the editor holds usable data: a positive amount
    /// and a non-empty date — so a failed receipt can't be resolved with junk.
    private var canSave: Bool {
        guard let dollars = Double(amountText), dollars > 0 else { return false }
        return !txnDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            LbHeader(title: "Review receipt", onClose: onClose, onAdd: {}, showsAdd: false)
            Form {
                Section("Details") {
                    TextField("Merchant", text: $merchant)
                        .accessibilityIdentifier(AccessibilityID.emailInReviewMerchant)
                    TextField("Amount (AUD)", text: $amountText).keyboardType(.decimalPad)
                        .accessibilityIdentifier(AccessibilityID.emailInReviewAmount)
                    TextField("Date (YYYY-MM-DD)", text: $txnDate)
                    Picker("Category", selection: $catKey) {
                        ForEach(catKeys, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                }
                Section {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier(AccessibilityID.emailInReviewSave)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream)
        .keyboardDismissButton() // hide-keyboard accessory for merchant/amount/date fields
        .accessibilityIdentifier(AccessibilityID.emailInReviewScreen)
        .onAppear {
            guard !loaded, let t = txn else { return }
            merchant = t.merchant
            amountText = String(format: "%.2f", Double(abs(t.amountCents)) / 100.0)
            txnDate = t.txnDate
            catKey = t.catKey
            loaded = true
        }
    }

    private func save() {
        guard canSave, let t = txn else { return }
        let dollars = Double(amountText) ?? 0
        let cents = Int((dollars * 100).rounded())
        vm.save(t, merchant: merchant, amountCentsAbs: cents, txnDate: txnDate, catKey: catKey)
        onClose()
    }
}
