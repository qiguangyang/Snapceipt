import Foundation

/// Test-only URLProtocol that returns canned responses and captures the last request.
/// Register it on a URLSessionConfiguration via `protocolClasses = [MockURLProtocol.self]`.
final class MockURLProtocol: URLProtocol {
    /// Per-test handler: given the outgoing request, return the status + headers + body to reply with.
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (Int, [String: String], Data))?
    /// The most recent intercepted request (read its headers/body/url in assertions).
    nonisolated(unsafe) static var lastRequest: URLRequest?
    private static let lock = NSLock()

    /// Install a handler + clear the captured request. Call at the top of each test.
    static func setHandler(_ handler: @escaping (URLRequest) throws -> (Int, [String: String], Data)) {
        lock.lock(); defer { lock.unlock() }
        requestHandler = handler
        lastRequest = nil
    }

    /// Build a URLSession whose only protocol is this mock.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.lock.lock()
        MockURLProtocol.lastRequest = request
        let handler = MockURLProtocol.requestHandler
        MockURLProtocol.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, headers, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
