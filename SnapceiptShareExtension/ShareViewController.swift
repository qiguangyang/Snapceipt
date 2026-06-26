import UIKit
import PDFKit
import UniformTypeIdentifiers
import OSLog

private let shareLog = Logger(subsystem: "app.snapceipt", category: "share")

/// Mirrors UIApplication's `open(_:options:completionHandler:)` (ObjC selector
/// `openURL:options:completionHandler:`), which is compile-time-unavailable to extensions. Casting
/// the responder-chain UIApplication to this @objc protocol dispatches the real method at runtime.
@objc private protocol URLOpening {
    @objc func open(_ url: URL, options: [AnyHashable: Any], completionHandler: ((Bool) -> Void)?)
}

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
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        var wrote = false
        for item in items {
            for provider in item.attachments ?? [] {
                // PDF first: a native PDF carries selectable text we can feed to extraction
                // (far better than re-OCRing a rendered page). public.image is the catch-all.
                if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                    wrote = await ingestPDF(provider) || wrote
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    wrote = await ingestImage(provider) || wrote
                }
            }
        }
        // Open the host app so it reads the receipt RIGHT AWAY (its inbox drain runs on foreground /
        // launch). NOTE: extensionContext.open() does NOT work for Share Extensions (Today widgets
        // only) — we walk the responder chain to UIApplication and invoke openURL: at runtime. If
        // that ever fails, the receipt still imports next time the app opens (the App Group inbox).
        shareLog.info("share: wrote=\(wrote, privacy: .public)")
        if wrote, let url = URL(string: "snapceipt://import") {
            openHostApp(url)
            // Let the openURL: dispatch reach the system before we tear down the extension process.
            try? await Task.sleep(for: .milliseconds(400))
        }
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    /// Launch the containing app via its URL scheme. `UIApplication.shared`/`open(_:)` are unavailable
    /// to extensions at compile time, so we find the live UIApplication on the responder chain and
    /// `perform("openURL:")` at runtime — the standard (and only reliable) way for a Share Extension
    /// to open its host app.
    private func openHostApp(_ url: URL) {
        let legacy = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self
        var hop = 0
        while let r = responder {
            shareLog.info("openHostApp hop \(hop): \(String(describing: type(of: r)), privacy: .public)")
            // Modern UIApplication.open(_:options:completionHandler:) via the @objc protocol cast.
            if let opener = r as AnyObject as? URLOpening {
                shareLog.info("openHostApp: open(_:options:) via \(String(describing: type(of: r)), privacy: .public)")
                opener.open(url, options: [:], completionHandler: nil)
                return
            }
            // Fallback to the legacy single-arg openURL: selector.
            if r.responds(to: legacy) {
                shareLog.info("openHostApp: legacy openURL: via \(String(describing: type(of: r)), privacy: .public)")
                r.perform(legacy, with: url)
                return
            }
            responder = r.next
            hop += 1
        }
        shareLog.error("openHostApp: no opener on the responder chain after \(hop) hops")
    }

    private func ingestImage(_ provider: NSItemProvider) async -> Bool {
        guard let data = await loadData(provider, UTType.image.identifier),
              let image = UIImage(data: data) else { return false }
        do { try ShareInbox.write(jpeg: Self.jpeg(from: image), text: nil); return true }
        catch { return false }
    }

    private func ingestPDF(_ provider: NSItemProvider) async -> Bool {
        guard let data = await loadData(provider, UTType.pdf.identifier),
              let doc = PDFDocument(data: data), let page = doc.page(at: 0) else { return false }
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
        do { try ShareInbox.write(jpeg: Self.jpeg(from: image), text: page.string); return true }
        catch { return false }
    }

    private func loadData(_ provider: NSItemProvider, _ type: String) async -> Data? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                if let url = item as? URL {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
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
