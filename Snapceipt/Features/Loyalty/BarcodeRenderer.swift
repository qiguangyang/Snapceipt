import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

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

    // MARK: - EAN-13 (filled in Task 3)

    static func ean13(value: String, scale: CGFloat) -> UIImage? { nil }
}
