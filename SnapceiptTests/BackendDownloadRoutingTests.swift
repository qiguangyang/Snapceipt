import Foundation
import SwiftData
import Testing
import UIKit
@testable import Snapceipt

@MainActor
@Suite(.serialized)
struct BackendDownloadRoutingTests {
    @Test("relative invoice PDF downloads stay on the configured backend")
    func relativeInvoicePDF() async throws {
        try await checkInvoicePDF(path: "/invoices/dl/backend-routing-regression",
                                  expectedHost: BackendConfig.configuredBaseURL.host!)
    }

    @Test("absolute invoice PDF downloads retain their server-provided host")
    func absoluteInvoicePDF() async throws {
        try await checkInvoicePDF(path: "https://downloads.example.com/invoices/dl/backend-routing-regression",
                                  expectedHost: "downloads.example.com")
    }

    private func checkInvoicePDF(path: String, expectedHost: String) async throws {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        let context = ModelContext(container)
        let id = UUID().uuidString
        context.insert(Invoice(id: "invoice-\(id)", userId: "u", profileId: "p",
                               number: "INV-ROUTING", totalCents: 100, status: "issued"))
        context.insert(Transaction(id: id, userId: "u", profileId: "p", merchant: "Client",
                                   catKey: CategoryKey.income.rawValue, amountCents: 100,
                                   txnDate: "2026-10-02", mode: "business", note: "Invoice INV-ROUTING",
                                   source: "invoice"))
        try context.save()
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        InvoiceDownloadURLProtocol.prepare(pdf: renderer.pdfData { $0.beginPage() })
        URLProtocol.registerClass(InvoiceDownloadURLProtocol.self)
        defer { URLProtocol.unregisterClass(InvoiceDownloadURLProtocol.self) }
        let api = MockAPIClient()
        api.invoicePdfHandler = { _ in InvoicePdfResponse(pdfUrl: path, expiresAt: nil) }
        let vm = ReceiptDetailViewModel(context: context, transactionId: id, api: api)
        let deadline = ContinuousClock.now + .seconds(5)
        while (vm.image == nil || vm.isLoadingImage), ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(!vm.isLoadingImage)
        #expect(InvoiceDownloadURLProtocol.url?.host == expectedHost)
        #expect(vm.image != nil)
        if let cache = ReceiptDetailViewModel.localImageURL(for: id) {
            try? FileManager.default.removeItem(at: cache)
        }
    }
}

private final class InvoiceDownloadURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var capturedURL: URL?
    nonisolated(unsafe) private static var pdf = Data()
    static var url: URL? { lock.lock(); defer { lock.unlock() }; return capturedURL }
    static func prepare(pdf: Data) {
        lock.lock(); defer { lock.unlock() }
        capturedURL = nil
        self.pdf = pdf
    }
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/invoices/dl/backend-routing-regression"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.capturedURL = request.url
        let data = Self.pdf
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/pdf"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
