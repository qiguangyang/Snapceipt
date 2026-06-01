import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// Pure barcode renderer. No SwiftUI/SwiftData, no hidden time/Calendar — every
/// input is injected, so it is fully unit-testable. Returns a crisp, POS-grade
/// image for `value` in `format`, or nil when the value is invalid for the format
/// (the caller then shows a number-only fallback).
enum BarcodeRenderer {

    /// Foreground/background: near-black `#111` bars on white.
    private static let foreground = CIColor(red: 0x11/255.0, green: 0x11/255.0, blue: 0x11/255.0)
    private static let background = CIColor(red: 1, green: 1, blue: 1)

    static func image(value: String, format: LoyaltyCard.BarcodeFormat, scale: CGFloat) -> UIImage? {
        guard !value.isEmpty else { return nil }
        switch format {
        case .code128: return coreImage(value: value, generator: "CICode128BarcodeGenerator", scale: scale)
        case .qr:      return coreImage(value: value, generator: "CIQRCodeGenerator", scale: scale)
        case .pdf417:  return coreImage(value: value, generator: "CIPDF417BarcodeGenerator", scale: scale)
        case .aztec:   return coreImage(value: value, generator: "CIAztecCodeGenerator", scale: scale)
        case .ean13:   return ean13(value: value, scale: scale)   // filled in Task 3
        }
    }

    // MARK: - CoreImage

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Generate via a CIFilter, tint #111-on-#fff, then scale with NEAREST-NEIGHBOUR
    /// (integer transform before rasterizing) so bar edges stay hard.
    private static func coreImage(value: String, generator: String, scale: CGFloat) -> UIImage? {
        guard let data = value.data(using: .ascii) ?? value.data(using: .utf8),
              let filter = CIFilter(name: generator) else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        // Code128 exposes a quiet-zone control; the others include their own quiet zone.
        if generator == "CICode128BarcodeGenerator" {
            filter.setValue(7.0, forKey: "inputQuietSpace")
        }
        guard let output = filter.outputImage else { return nil }

        let tinted = tint(output)
        // Integer scale up first (no interpolation), then rasterize.
        let s = Swift.max(1, scale)
        let scaled = tinted.transformed(by: CGAffineTransform(scaleX: s, y: s))
        guard let cg = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    /// Map the generator's 1-bit output to #111 bars on a #fff background.
    private static func tint(_ image: CIImage) -> CIImage {
        let f = CIFilter.falseColor()
        f.inputImage = image
        f.color0 = background   // 0 -> white
        f.color1 = foreground   // 1 -> #111
        return f.outputImage ?? image
    }

    // MARK: - EAN-13 / UPC-A (hand-rolled)

    /// L-code (left, parity even) for digits 0-9 — 7 modules each.
    private static let lCode = [
        "0001101","0011001","0010011","0111101","0100011",
        "0110001","0101111","0111011","0110111","0001011",
    ]
    /// G-code (left, parity odd).
    private static let gCode = [
        "0100111","0110011","0011011","0100001","0011101",
        "0111001","0000101","0010001","0001001","0010111",
    ]
    /// R-code (right) — the complement of L-code.
    private static let rCode = [
        "1110010","1100110","1101100","1000010","1011100",
        "1001110","1010000","1000100","1001000","1110100",
    ]
    /// Parity pattern for the left 6 digits, selected by the first digit.
    private static let parity = [
        "LLLLLL","LLGLGG","LLGGLG","LLGGGL","LGLLGG",
        "LGGLLG","LGGGLL","LGLGLG","LGLGGL","LGGLGL",
    ]

    /// mod-10 check digit for the first 12 digits of an EAN-13 (odd positions ×1,
    /// even positions ×3, from the left, 0-indexed). Returns nil if not 12 digits.
    static func ean13CheckDigit(_ first12: String) -> Int? {
        let d = first12.compactMap { $0.wholeNumberValue }
        guard d.count == 12 else { return nil }
        var sum = 0
        for (i, n) in d.enumerated() { sum += (i % 2 == 0) ? n : n * 3 }
        return (10 - (sum % 10)) % 10
    }

    /// Normalize a raw value to a valid 13-digit EAN-13 string (UPC-A 12 digits get a
    /// leading 0; a 12-digit value is treated as first-12 + computed check). Returns
    /// nil for any non-digit / wrong-length / bad-checksum input.
    static func normalizedEAN13(_ raw: String) -> String? {
        let digits = raw.filter { $0.isNumber }
        guard digits.count == raw.count else { return nil }   // reject non-digit chars
        let value: String
        switch digits.count {
        case 13:
            value = digits
        case 12:
            value = "0" + digits
        default:
            return nil
        }
        let first12 = String(value.prefix(12))
        let given = value.last!.wholeNumberValue!
        guard let check = ean13CheckDigit(first12), check == given else { return nil }
        return value
    }

    /// The 95-module bit string (1 = bar) for a valid 13-digit EAN-13 value, or nil.
    static func ean13Modules(_ value: String) -> String? {
        guard let v = normalizedEAN13(value) else { return nil }
        let d = v.compactMap { $0.wholeNumberValue }
        let pat = parity[d[0]]   // first digit picks the L/G pattern for the left 6
        var s = "101"            // left guard
        for i in 1...6 {
            s += (Array(pat)[i - 1] == "L") ? lCode[d[i]] : gCode[d[i]]
        }
        s += "01010"            // centre guard
        for i in 7...12 { s += rCode[d[i]] }
        s += "101"              // right guard
        return s
    }

    /// Draw the EAN-13 modules into a CGContext: fixed module width, #111 on #fff,
    /// with a >=7-module quiet zone each side. No interpolation (we draw exact rects).
    static func ean13(value: String, scale: CGFloat) -> UIImage? {
        guard let mods = ean13Modules(value) else { return nil }
        let module = Swift.max(1, scale)
        let quiet: CGFloat = 7 * module
        let width = quiet * 2 + CGFloat(mods.count) * module
        let height = CGFloat(80) * (module / 2)   // proportional, ~POS aspect
        let size = CGSize(width: width, height: Swift.max(40, height))

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            cg.interpolationQuality = .none
            cg.setFillColor(UIColor.white.cgColor)
            cg.fill(CGRect(origin: .zero, size: size))
            cg.setFillColor(UIColor(red: 0x11/255.0, green: 0x11/255.0, blue: 0x11/255.0, alpha: 1).cgColor)
            var x = quiet
            for ch in mods {
                if ch == "1" {
                    cg.fill(CGRect(x: x, y: 0, width: module, height: size.height))
                }
                x += module
            }
        }
    }
}

extension LoyaltyCard.BarcodeFormat {
    /// Map a Vision-recognized symbology to a supported BarcodeFormat. Vision reports
    /// UPC-A as `.ean13` with a leading 0 (the EAN-13 renderer handles that). Any other
    /// symbology (`.upce`, `.ean8`, …) returns nil — the number is still captured,
    /// `barcodeFormat` is left nil, and the detail view shows number-only.
    init?(symbology: VNBarcodeSymbology) {
        switch symbology {
        case .code128: self = .code128
        case .ean13:   self = .ean13
        case .qr:      self = .qr
        case .aztec:   self = .aztec
        case .pdf417:  self = .pdf417
        default:       return nil
        }
    }
}
