import SwiftUI

/// Currency entry that stores integer cents but lets the user type `dollars.cents`.
/// Shows a grey "0.00" placeholder and stays empty at zero, so a fresh line item has
/// nothing to clear before the user types (tapping an empty field is ready for input).
struct LinePriceField: View {
    @Binding var cents: Int
    var placeholder: String = "0.00"
    @State private var text: String = ""

    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(.decimalPad)
            .onAppear { if text.isEmpty { text = Self.display(cents) } }
            .onChange(of: text) { _, t in
                let c = Self.cents(from: t)
                if c != cents { cents = c }
            }
    }

    /// Cents → an editable dollar string; "" at zero so the placeholder shows.
    static func display(_ cents: Int) -> String {
        guard cents != 0 else { return "" }
        return cents % 100 == 0 ? String(cents / 100) : String(format: "%.2f", Double(cents) / 100)
    }

    /// "12.50" → 1250 cents; tolerates a comma decimal separator + stray characters.
    static func cents(from s: String) -> Int {
        let cleaned = s.replacingOccurrences(of: ",", with: ".").filter { $0.isNumber || $0 == "." }
        guard let dollars = Double(cleaned) else { return 0 }
        return Int((dollars * 100).rounded())
    }
}
