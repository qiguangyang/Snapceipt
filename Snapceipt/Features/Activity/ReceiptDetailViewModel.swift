import Foundation
import SwiftData
import UIKit

/// Loads everything the receipt detail page shows: the transaction, the scanned image
/// (from the local `PendingReceipt`), and its line items.
@Observable
@MainActor
final class ReceiptDetailViewModel {
    @ObservationIgnored private let context: ModelContext
    let transactionId: String
    private(set) var txn: Transaction?
    private(set) var row: ReceiptRow?
    private(set) var image: UIImage?
    private(set) var lineItems: [LineItem] = []

    init(context: ModelContext, transactionId: String) {
        self.context = context
        self.transactionId = transactionId
        load()
    }

    func load() {
        let tid = transactionId
        let t = (try? context.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == tid })))?.first
        txn = t
        row = t.map(ReceiptRow.init)
        // The scanned JPEG lives at the PendingReceipt's local path (absolute).
        let pr = (try? context.fetch(FetchDescriptor<PendingReceipt>(
            predicate: #Predicate { $0.transactionId == tid })))?.first
        if let path = pr?.imageLocalPath, !path.isEmpty {
            image = UIImage(contentsOfFile: path)
        }
        lineItems = (try? context.fetch(FetchDescriptor<LineItem>(
            predicate: #Predicate { $0.transactionId == tid && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
    }
}
