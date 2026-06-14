import Foundation
import Testing
@testable import Snapceipt

@Suite(.serialized)
struct BasExportClientTests {
    private func makeClient() -> LiveAPIClient {
        let auth = AuthStore(); auth.clear()
        auth.save(SessionResponse(accessToken: "acc", refreshToken: "refresh-0123456789abcdef0123456789abcdef",
                                  expiresIn: 900, user: SessionUser(id: "u1", email: "a@b.com", displayName: "Ada")))
        return LiveAPIClient(baseURL: URL(string: "https://api.test")!, auth: auth,
                             session: MockURLProtocol.makeSession())
    }
    private func json(_ s: String) -> Data { Data(s.utf8) }

    @Test("bas export decodes the basPack result + posts the bas body")
    func basPack() async throws {
        let client = makeClient()
        MockURLProtocol.setHandler { _ in
            (200, ["Content-Type": "application/json"],
             self.json(#"{"pdfUrl":"/export/dl/p","csvUrl":"/export/dl/c","expiresAt":1790000000000,"emailed":false,"bas":{"g1":1100000,"oneA":100000,"oneB":30000,"netGst":70000,"payg":0,"totalPayable":70000}}"#))
        }
        let result = try await client.exportBas(profileId: "p1", from: "2026-04-01", to: "2026-06-30",
                                                paygInstalmentCents: 0, toEmail: nil)
        guard case let .basPack(pdfUrl, csvUrl, expiresAt, emailed, bas) = result else {
            Issue.record("expected .basPack"); return
        }
        #expect(pdfUrl == "/export/dl/p")
        #expect(csvUrl == "/export/dl/c")
        #expect(expiresAt == 1790000000000)
        #expect(emailed == false)
        #expect(bas.oneA == 100000 && bas.netGst == 70000 && bas.totalPayable == 70000)
        // body assertions
        let bodyData = MockURLProtocol.lastRequest?.httpBodyData() ?? Data()
        let obj = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        #expect(obj?["format"] as? String == "bas")
        #expect(obj?["from"] as? String == "2026-04-01")
        let basBody = obj?["bas"] as? [String: Any]
        #expect(basBody?["paygInstalmentCents"] as? Int == 0)
    }

    /// MAJOR 1 regression guard (spec §4.7): the BAS-pinned export window must be PINNED to
    /// `basWindowForActive` (the SAME window that keys the PAYG + drives the on-screen
    /// Simpler-BAS spine), NOT the Reports `exportPeriod` (default `.month`). For a quarterly
    /// profile this is the difference between POSTing the full quarter (Apr–Jun) and a single
    /// month (May) alongside the quarterly PAYG — so the emitted from/to must equal the quarter
    /// window. This mirrors RootView.exportWindow's pinned branch + `from`/`to` formatting
    /// exactly (window.start; window.end − 1 day, via ExportDateFormatter).
    @Test("BAS-pinned export pins from/to to the BAS (quarter) window, not the month default")
    func basPinnedWindowMatchesBasWindow() async throws {
        // FY-Q4 (Apr–Jun 2026) of a quarterly profile, mid-quarter so month ≠ quarter.
        let now = ExportDateFormatter.shared.date(from: "2026-05-15")!
        let startMonth = 7

        // The window RootView pins the BAS pack to (basWindowForActive == Period.quarter window).
        let quarter = Period.quarter.window(now: now, startMonth: startMonth)
        let pinnedFrom = ExportDateFormatter.shared.string(from: quarter.start)
        let pinnedTo = ExportDateFormatter.shared.string(from: quarter.end.addingTimeInterval(-86_400))
        #expect(pinnedFrom == "2026-04-01")
        #expect(pinnedTo == "2026-06-30")

        // The buggy fallback (exportPeriod default `.month`) would have drifted to May only —
        // assert it genuinely differs so this test would fail if the pin regressed.
        let month = Period.month.window(now: now, startMonth: startMonth)
        let driftFrom = ExportDateFormatter.shared.string(from: month.start)
        let driftTo = ExportDateFormatter.shared.string(from: month.end.addingTimeInterval(-86_400))
        #expect(driftFrom == "2026-05-01")
        #expect(driftTo == "2026-05-31")
        #expect(pinnedFrom != driftFrom)
        #expect(pinnedTo != driftTo)

        // Drive the actual BAS export with the PINNED window and assert the POSTed body
        // carries the quarter from/to (the value the ExportSheet forwards verbatim).
        let client = makeClient()
        MockURLProtocol.setHandler { _ in
            (200, ["Content-Type": "application/json"],
             self.json(#"{"pdfUrl":"/p","csvUrl":"/c","expiresAt":1,"emailed":false,"bas":{"g1":0,"oneA":0,"oneB":0,"netGst":0,"payg":0,"totalPayable":0}}"#))
        }
        _ = try await client.exportBas(profileId: "p1", from: pinnedFrom, to: pinnedTo,
                                       paygInstalmentCents: 0, toEmail: nil)
        let bodyData = MockURLProtocol.lastRequest?.httpBodyData() ?? Data()
        let obj = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        #expect(obj?["from"] as? String == "2026-04-01")
        #expect(obj?["to"] as? String == "2026-06-30")
    }
}

private extension URLRequest {
    func httpBodyData() -> Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data(); let bufSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize); defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufSize); if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
