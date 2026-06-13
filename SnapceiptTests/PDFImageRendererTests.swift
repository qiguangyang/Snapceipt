import Testing
import UIKit
@testable import Snapceipt

struct PDFImageRendererTests {

    /// A real one-page PDF generated in-memory (no fixture file needed).
    private func onePagePDF() -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 300))
        return renderer.pdfData { ctx in
            ctx.beginPage()
            UIColor.white.setFill()
            ctx.cgContext.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
            ("TOTAL 12.34" as NSString).draw(
                at: CGPoint(x: 12, y: 12),
                withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
        }
    }

    @Test("renders the first page of a valid PDF to a non-nil image, longest side ~= maxDimension")
    func rendersFirstPage() throws {
        let img = try #require(PDFImageRenderer.firstPage(onePagePDF(), maxDimension: 1000))
        let longest = max(img.size.width, img.size.height)
        #expect(longest > 800 && longest <= 1000)            // 300 -> 1000 (scaled up)
        #expect(img.size.width < img.size.height)            // portrait aspect preserved
    }

    @Test("returns nil for non-PDF and empty data")
    func nilForGarbage() {
        #expect(PDFImageRenderer.firstPage(Data([0x00, 0x01, 0x02])) == nil)
        #expect(PDFImageRenderer.firstPage(Data()) == nil)
    }
}
