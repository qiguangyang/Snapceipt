import WebKit
import UIKit

/// Renders a hosted HTML quote page (the `/q/:token` link) to a PDF file on-device
/// (spec §4): load the URL in an off-screen `WKWebView`, wait for the page to finish,
/// `createPDF`, and write a temp file. `@MainActor` (WebKit is main-thread only).
@MainActor
final class QuotePdfRenderer: NSObject, WKNavigationDelegate {
    enum RenderError: Error { case load, pdf }

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Void, Error>?

    /// Load `url`, render to PDF, and return a temp file URL named `<fileName>.pdf`.
    func renderPDF(from url: URL, fileName: String) async throws -> URL {
        // A4-ish frame so the print-friendly CSS lays out correctly (595×842 pt).
        let config = WKWebViewConfiguration()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 595, height: 842), configuration: config)
        web.navigationDelegate = self
        self.webView = web

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.continuation = cont
            web.load(URLRequest(url: url))
        }

        // Give layout/web-fonts a beat to settle before snapshotting.
        try? await Task.sleep(nanoseconds: 300_000_000)

        let pdfData: Data = try await withCheckedThrowingContinuation { cont in
            web.createPDF(configuration: WKPDFConfiguration()) { result in
                switch result {
                case .success(let data): cont.resume(returning: data)
                case .failure: cont.resume(throwing: RenderError.pdf)
                }
            }
        }

        let safe = fileName.replacingOccurrences(of: "/", with: "-")
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).pdf")
        try pdfData.write(to: fileURL, options: .atomic)
        self.webView = nil
        return fileURL
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.continuation?.resume(); self.continuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.continuation?.resume(throwing: RenderError.load); self.continuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.continuation?.resume(throwing: RenderError.load); self.continuation = nil
        }
    }
}
