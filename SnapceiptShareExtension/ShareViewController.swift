import UIKit
import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import OSLog

private let shareLog = Logger(subsystem: "app.snapceipt", category: "share")

/// Share Extension entry point. Accepts an image or PDF shared from another app, shows a popup
/// with the receipt, READS it on-device (OCR + Foundation Models), displays merchant/total/date,
/// and on "Save to Snapceipt" drops the JPEG + parsed draft into the App Group inbox (`ShareInbox`)
/// for the app to file WITHOUT re-extracting. On a non-FM device (or if extraction fails) it still
/// shows the image and saves a JPEG-only handoff, so the app re-extracts the next time it opens.
/// There is no host-app launch — iOS blocks a Share Extension from opening its container app; the
/// App Group inbox is the contract, drained on the app's next launch/foreground.
final class ShareViewController: UIViewController {
    private let model = ShareReviewModel()
    /// Embedded text from a shared PDF (selectable text beats re-OCRing a rendered page).
    private var pdfText: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        embedPopup()
        Task { await loadAndRead() }
    }

    private func embedPopup() {
        let root = ShareReviewView(
            model: model,
            onSave: { [weak self] in self?.save() },
            onCancel: { [weak self] in self?.cancel() })
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }

    // MARK: Load + read

    /// Pull the shared image/PDF into memory, then run on-device extraction.
    private func loadAndRead() async {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        var loadedImage: UIImage?
        for item in items {
            for provider in item.attachments ?? [] where loadedImage == nil {
                // PDF first: a native PDF carries selectable text that beats re-OCRing a page.
                if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                    loadedImage = await imageFromPDF(provider)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    loadedImage = await imageFromImage(provider)
                }
            }
        }
        guard let image = loadedImage else {
            shareLog.error("share: no image/PDF in the shared item")
            // Nothing we can do with this share — dismiss.
            extensionContext?.cancelRequest(withError: NSError(
                domain: "app.snapceipt.share", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No image or PDF to read."]))
            return
        }
        model.image = image
        model.phase = .reading
        let draft = await extract(image: image, pdfText: pdfText)
        model.draft = draft
        model.phase = .ready
        shareLog.info("share: read done, hasDraft=\(draft != nil, privacy: .public)")
    }

    /// On-device extraction: OCR → layout rows → Foundation Models. Returns nil when FM is
    /// unavailable (older iOS / not eligible) or extraction throws, so the caller falls back to a
    /// JPEG-only handoff (the app re-extracts on open). A PDF's embedded text skips OCR entirely.
    private func extract(image: UIImage, pdfText: String?) async -> ExtractedReceipt? {
        guard let extractor = OnDeviceAI.makeExtractor() else { return nil }
        let capturedAt = ExtractedReceipt.ymd(from: Date()) ?? ""
        do {
            let lines: [RecognizedLine]
            if let pdfText, !pdfText.isEmpty {
                // PDF text is already in reading order (zero-box lines).
                lines = pdfText.split(separator: "\n", omittingEmptySubsequences: true).map {
                    RecognizedLine(text: String($0), confidence: 1, boundingBox: .zero)
                }
            } else {
                lines = try await OCR.recognize(in: image)
            }
            let rawText = lines.map(\.text).joined(separator: "\n")
            // Column-aligned 2D reconstruction (names left, prices right) so the model reads the
            // receipt's layout instead of a flat token stream — the fix for the dense item column.
            let layoutText = ReceiptRows.layoutGrid(from: lines)
            let extracted = try await extractor.extract(
                ocrText: rawText, layoutText: layoutText, capturedAt: capturedAt)
            // Geometry-based backstops (line-based, independent of row reconstruction): pair the
            // "Total" / "GST" labels with the amount on their OWN printed row, so neither can be
            // corrupted by row-merge/model errors.
            let withTotal = OnDeviceGuards.withGeometricTotal(extracted, lines: lines)
            return OnDeviceGuards.withGeometricGst(withTotal, lines: lines)
        } catch {
            shareLog.error("share: extraction failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }


    // MARK: Save / Cancel

    private func save() {
        guard let image = model.image else { cancel(); return }
        model.phase = .saving
        let jpeg = Self.jpeg(from: image)
        do {
            if let draft = model.draft {
                try ShareInbox.write(jpeg: jpeg, draft: draft)
            } else {
                // No on-device draft — hand off the JPEG (+ any PDF text) so the app re-extracts.
                try ShareInbox.write(jpeg: jpeg, text: pdfText)
            }
            shareLog.info("share: saved, hadDraft=\(self.model.draft != nil, privacy: .public)")
        } catch {
            shareLog.error("share: write failed: \(String(describing: error), privacy: .public)")
            extensionContext?.cancelRequest(withError: error)
            return
        }
        // Brief "Saved ✓" confirmation, then complete.
        model.phase = .saved
        Task {
            try? await Task.sleep(for: .milliseconds(550))
            extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(
            domain: "app.snapceipt.share", code: NSUserCancelledError))
    }

    // MARK: Attachment loading

    private func imageFromImage(_ provider: NSItemProvider) async -> UIImage? {
        guard let data = await loadData(provider, UTType.image.identifier),
              let image = UIImage(data: data) else { return nil }
        // Flatten the shared PHOTO the same way the in-app camera does — detect the receipt quad and
        // perspective-correct it — so a skewed/curled photo's rows line up for OCR. This is the key
        // difference vs in-app capture (which dewarps before reading); without it the dense item
        // column collapses. Falls back to the orientation-normalized original if nothing's detected.
        return Self.dewarpedReceipt(image)
    }

    private static func dewarpedReceipt(_ image: UIImage) -> UIImage {
        let up = image.normalizedUp()
        guard let quad = DocumentScan.detect(in: up),
              let flat = DocumentScan.dewarp(up, quad: quad) else { return up }
        return flat
    }

    private func imageFromPDF(_ provider: NSItemProvider) async -> UIImage? {
        guard let data = await loadData(provider, UTType.pdf.identifier),
              let doc = PDFDocument(data: data), let page = doc.page(at: 0) else { return nil }
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
        // Embedded text — nil/empty for a scanned (image-only) PDF, which we then OCR.
        pdfText = page.string
        return image
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
    /// save, so this only needs to be good enough for the saved image (and small enough to share).
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

private extension UIImage {
    /// Redraw in `.up` orientation so Vision/CoreImage (which read raw pixels, ignoring EXIF) detect
    /// + dewarp the receipt correctly on a shared photo.
    func normalizedUp() -> UIImage {
        guard imageOrientation != .up else { return self }
        return UIGraphicsImageRenderer(size: size).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
