import Foundation
import SwiftData
import UIKit

/// Loads everything the receipt detail page shows: the transaction, the scanned image
/// (from the local `PendingReceipt`), and its line items.
@Observable
@MainActor
final class ReceiptDetailViewModel {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let api: (any APIClient)?
    let transactionId: String
    private(set) var txn: Transaction?
    private(set) var row: ReceiptRow?
    private(set) var image: UIImage?
    private(set) var isLoadingImage = false
    private(set) var lineItems: [LineItem] = []

    init(context: ModelContext, transactionId: String, api: (any APIClient)? = nil) {
        self.context = context
        self.api = api
        self.transactionId = transactionId
        load()
    }

    func load() {
        let tid = transactionId
        let t = (try? context.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == tid })))?.first
        txn = t
        row = t.map(ReceiptRow.init)
        let pr = (try? context.fetch(FetchDescriptor<PendingReceipt>(
            predicate: #Predicate { $0.transactionId == tid })))?.first
        image = localImage(pr: pr)
        // The local JPEG is reclaimed after the R2 upload (ReceiptUploadQueue), so for an
        // already-uploaded receipt the only copy is on the server — fetch it back. An
        // invoice-income transaction has no receipt photo, so show the invoice PDF instead.
        if image == nil, api != nil {
            if t?.source == "invoice" {
                Task { await fetchInvoicePdfImage() }
            } else {
                Task { await fetchRemoteImage() }
            }
        }
        lineItems = (try? context.fetch(FetchDescriptor<LineItem>(
            predicate: #Predicate { $0.transactionId == tid && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
    }

    /// The reduced JPEG written at capture, resolved from the CURRENT container by its
    /// deterministic filename (a stored absolute path breaks across reinstalls); falls
    /// back to the path recorded on the `PendingReceipt` when present.
    private func localImage(pr: PendingReceipt?) -> UIImage? {
        if let url = Self.localImageURL(for: transactionId),
           let img = UIImage(contentsOfFile: url.path) { return img }
        if let path = pr?.imageLocalPath, !path.isEmpty { return UIImage(contentsOfFile: path) }
        return nil
    }

    /// `<Application Support>/receipts/<transactionId>.jpg` — matches where the capture
    /// flow writes the reduced JPEG (`CaptureViewModel.persistReducedImage`).
    static func localImageURL(for transactionId: String) -> URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return dir.appendingPathComponent("receipts", isDirectory: true)
            .appendingPathComponent("\(transactionId).jpg")
    }

    /// Fetch the receipt JPEG from R2 and re-cache it locally so subsequent opens are
    /// instant + offline. Best-effort: a failure leaves `image` nil (placeholder shown).
    func fetchRemoteImage() async {
        guard let api else { return }
        isLoadingImage = true
        defer { isLoadingImage = false }
        guard let data = try? await api.fetchReceiptImage(transactionId: transactionId) else { return }
        // Images decode directly; PDF receipts (email-in) aren't decodable as a UIImage, so render
        // their first page via PDFKit. Without this the detail page showed no receipt for PDFs.
        let directImage = UIImage(data: data)
        guard let img = directImage ?? PDFImageRenderer.firstPage(data) else { return }
        image = img
        // Cache a DECODABLE JPEG so the offline read (UIImage(contentsOfFile:)) works for PDFs too:
        // reuse the original bytes for images, the rendered first page for PDFs.
        let cacheBytes = directImage != nil ? data : img.jpegData(compressionQuality: 0.9)
        if let bytes = cacheBytes, let url = Self.localImageURL(for: transactionId) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Match the capture-time protection class (NSFileProtectionComplete) for the re-cached file.
            try? bytes.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }

    /// For an invoice-income transaction: resolve the linked invoice, fetch its PDF, and render
    /// the first page so the transaction page shows the invoice inline (mirrors how email-in
    /// PDF receipts render). Best-effort — a failure leaves `image` nil.
    func fetchInvoicePdfImage() async {
        guard let api, let txn, let invoice = linkedInvoice(for: txn) else { return }
        isLoadingImage = true
        defer { isLoadingImage = false }
        // POST /invoices/:id/pdf (re)builds the PDF and returns a short-lived signed download URL.
        guard let resp = try? await api.invoicePdf(invoice.id) else { return }
        let urlStr = resp.pdfUrl.hasPrefix("http") ? resp.pdfUrl : "\(BackendConfig.configuredBaseURL.absoluteString)\(resp.pdfUrl)"
        guard let url = URL(string: urlStr),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let img = PDFImageRenderer.firstPage(data) else { return }
        image = img
        // Cache the rendered first page (same path as receipts) so re-opens are instant + offline.
        if let cacheUrl = Self.localImageURL(for: transactionId),
           let bytes = img.jpegData(compressionQuality: 0.9) {
            try? FileManager.default.createDirectory(
                at: cacheUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? bytes.write(to: cacheUrl, options: [.atomic, .completeFileProtection])
        }
    }

    /// Resolve the Invoice that produced an invoice-income transaction. The income txn is tagged
    /// with note = "Invoice <number>" (or "Invoice <id>" when unnumbered) on the same profile.
    func linkedInvoice(for txn: Transaction) -> Invoice? {
        guard txn.source == "invoice", let note = txn.note, note.hasPrefix("Invoice ") else { return nil }
        let key = String(note.dropFirst("Invoice ".count))
        let pid = txn.profileId
        let all = (try? context.fetch(FetchDescriptor<Invoice>(
            predicate: #Predicate { $0.deletedAt == nil }))) ?? []
        return all.first { $0.profileId == pid && ($0.number == key || $0.id == key) }
    }
}
