import SwiftUI

struct CatalogEditorView: View {
    let store: CatalogStore
    let item: CatalogItem?
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var description = ""
    @State private var unit = ""
    @State private var price = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Description", text: $description, axis: .vertical)
                TextField("Unit (optional)", text: $unit)
                TextField("Unit price excluding GST", text: $price).keyboardType(.decimalPad)
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle(item == nil ? "Add saved item" : "Edit saved item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .onAppear {
                description = item?.itemDescription ?? ""
                unit = item?.unitLabel ?? ""
                price = item.map { NSDecimalNumber(value: $0.unitPriceCents).dividing(by: 100).stringValue } ?? ""
            }
        }
    }

    private func save() {
        let text = price.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: #"^\d+(\.\d{1,2})?$"#, options: .regularExpression) != nil,
              let decimal = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
              decimal >= 0, decimal <= 10_000_000 else {
            errorMessage = "Enter a valid price with up to two decimal places."
            return
        }
        let cents = decimal * 100
        var original = cents, rounded = Decimal()
        NSDecimalRound(&rounded, &original, 0, .plain)
        guard cents == rounded else {
            errorMessage = "Enter a valid price with up to two decimal places."
            return
        }
        do {
            _ = try store.save(id: item?.id, description: description, unitLabel: unit,
                               unitPriceCents: NSDecimalNumber(decimal: cents).intValue)
            onSaved(); dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
