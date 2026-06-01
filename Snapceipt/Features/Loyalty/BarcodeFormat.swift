import Foundation

extension LoyaltyCard {
    /// The five supported barcode symbologies. Raw values are the exact strings
    /// stored in `barcodeFormat` (and validated by the D1 CHECK server-side).
    enum BarcodeFormat: String, CaseIterable, Sendable {
        case code128
        case ean13
        case qr
        case aztec
        case pdf417
    }

    /// Typed view over the raw `barcodeFormat` storage. Storage stays `String?`
    /// for sync symmetry; this only bridges read/write to the enum.
    var format: BarcodeFormat? {
        get { barcodeFormat.flatMap(BarcodeFormat.init(rawValue:)) }
        set { barcodeFormat = newValue?.rawValue }
    }
}
