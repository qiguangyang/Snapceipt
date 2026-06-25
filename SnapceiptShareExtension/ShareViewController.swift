import UIKit
import PDFKit
import UniformTypeIdentifiers

/// Share Extension entry point. Accepts an image or PDF shared from another app, reduces it to a
/// JPEG (rasterizing a PDF's first page and keeping its embedded text), and drops it in the App
/// Group inbox (`ShareInbox`). The main Snapceipt app imports it through the normal
/// capture→extract→save pipeline the next time it opens. There is no UI — it processes the
/// attachments and dismisses immediately, so sharing feels instant.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        Task { await handleShare() }
    }

    private func handleShare() async {
        defer { extensionContext?.completeRequest(returningItems: nil, completionHandler: nil) }
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        for item in items {
            for provider in item.attachments ?? [] {
                // PDF first: a native PDF carries selectable text we can feed to extraction
                // (far better than re-OCRing a rendered page). public.image is the catch-all.
                if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                    await ingestPDF(provider)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    await ingestImage(provider)
                }
            }
        }
    }

    private func ingestImage(_ provider: NSItemProvider) async {
        guard let data = await loadData(provider, UTType.image.identifier),
              let image = UIImage(data: data) else { return }
        try? ShareInbox.write(jpeg: Self.jpeg(from: image), text: nil)
    }

    private func ingestPDF(_ provider: NSItemProvider) async {
        guard let data = await loadData(provider, UTType.pdf.identifier),
              let doc = PDFDocument(data: data), let page = doc.page(at: 0) else { return }
        let bounds = page.bounds(for: .mediaBox)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2   // render at 2x so small receipt type stays legible for OCR
        let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: bounds.size))
            ctx.cgContext.translateBy(x: 0, y: bounds.size.height)
            ctx.cgContext.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: ctx.cgContext)
        }
        // Embedded text — nil/empty for a scanned (image-only) PDF, which the app then OCRs.
        try? ShareInbox.write(jpeg: Self.jpeg(from: image), text: page.string)
    }

    private func loadData(_ provider: NSItemProvider, _ type: String) async -> Data? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                if let url = item as? URL {
                    cont.resume(returning: try? Data(contentsOf: url))
                } else if let data = item as? Data {
                    cont.resume(returning: data)
                } else if let image = item as? UIImage {
                    cont.resume(returning: image.jpegData(compressionQuality: 0.9))
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// Downscale to a sane longest-edge and JPEG-encode for the handoff. The app re-reduces it on
    /// save, so this only needs to be good enough for OCR + extraction (and small enough to share).
    static func jpeg(from image: UIImage, maxEdge: CGFloat = 2200, quality: CGFloat = 0.85) -> Data {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxEdge else { return image.jpegData(compressionQuality: quality) ?? Data() }
        let s = maxEdge / longest
        let size = CGSize(width: image.size.width * s, height: image.size.height * s)
        let scaled = UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return scaled.jpegData(compressionQuality: quality) ?? Data()
    }
}
