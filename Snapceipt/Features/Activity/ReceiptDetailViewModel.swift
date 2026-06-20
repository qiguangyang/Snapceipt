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
        // already-uploaded receipt the only copy is on the server — fetch it back.
        if image == nil, api != nil {
            Task { await fetchRemoteImage() }
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
        guard let data = try? await api.fetchReceiptImage(transactionId: transactionId),
              let img = UIImage(data: data) else { return }
        image = img
        if let url = Self.localImageURL(for: transactionId) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Match the capture-time protection class (NSFileProtectionComplete) for the
            // re-cached receipt JPEG.
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }
}
