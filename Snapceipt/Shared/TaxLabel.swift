import Foundation

/// The tax label for a scanned receipt, localized to its currency code:
/// Australia & New Zealand → "GST"; United States → "Sales tax"; Canada → "GST/HST".
/// Falls back to "GST". `currency` is the receipt's `currencyCode` (AUD/NZD/USD/CAD) — see the
/// server's `normalizeCurrency`. Named distinctly from `Transaction.taxLabel` (a freeform note).
func receiptTaxLabel(for currency: String) -> String {
    switch currency.uppercased() {
    case "USD": return "Sales tax"
    case "CAD": return "GST/HST"
    default:    return "GST" // AUD, NZD, and any fallback
    }
}
