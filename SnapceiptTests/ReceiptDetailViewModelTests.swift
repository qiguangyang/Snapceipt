import Testing
import SwiftData
import UIKit
@testable import Snapceipt

/// The receipt detail page loads the scanned image. After the R2 upload reclaims the local
/// JPEG, the only copy is on the server — the VM must fetch it back (and otherwise show no
/// image rather than crash).
@MainActor
struct ReceiptDetailViewModelTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        return ModelContext(container)
    }

    private func seedTxn(_ ctx: ModelContext, id: String) throws {
        ctx.insert(Transaction(id: id, userId: "u1", profileId: "p1",
                               merchant: "Cafe", catKey: "meals", amountCents: -1250,
                               txnDate: "2026-06-20"))
        try ctx.save()
    }

    /// A real (tiny) JPEG so `UIImage(data:)` decodes it.
    private func jpegData() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        let img = renderer.image { ctx in
            UIColor.gray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        return img.jpegData(compressionQuality: 0.8)!
    }

    @Test("no local file + no api -> image stays nil (no crash)")
    func noImageNoApi() throws {
        let ctx = try makeContext()
        try seedTxn(ctx, id: "tdetail-none")
        let vm = ReceiptDetailViewModel(context: ctx, transactionId: "tdetail-none")
        #expect(vm.txn != nil)
        #expect(vm.image == nil)
    }

    @Test("no local file -> fetches the receipt image from R2")
    func fetchesFromR2() async throws {
        let ctx = try makeContext()
        try seedTxn(ctx, id: "tdetail-r2")
        let api = MockAPIClient()
        let data = jpegData()
        api.fetchReceiptImageHandler = { txnId in txnId == "tdetail-r2" ? data : nil }
        let vm = ReceiptDetailViewModel(context: ctx, transactionId: "tdetail-r2", api: api)
        await vm.fetchRemoteImage()
        #expect(vm.image != nil)
    }

    @Test("R2 returns nothing -> image stays nil")
    func r2Empty() async throws {
        let ctx = try makeContext()
        try seedTxn(ctx, id: "tdetail-empty")
        let api = MockAPIClient()
        api.fetchReceiptImageHandler = { _ in nil }
        let vm = ReceiptDetailViewModel(context: ctx, transactionId: "tdetail-empty", api: api)
        await vm.fetchRemoteImage()
        #expect(vm.image == nil)
    }
}
