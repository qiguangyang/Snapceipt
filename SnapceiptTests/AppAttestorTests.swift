import XCTest
@testable import Snapceipt

/// App Attest is unavailable on the Simulator (`DCAppAttestService.isSupported == false`),
/// so `AppAttestor` must fail OPEN and yield no headers. This keeps every auth-bootstrap
/// flow unattested-but-functional in CI/sim (and on any device where attestation errors),
/// letting the server's attest policy — not the client — decide acceptance.
final class AppAttestorTests: XCTestCase {
    func testUnsupportedYieldsNoHeaders() async {
        // On the Simulator DCAppAttestService.isSupported == false → headers empty (fail-open to server).
        let a = AppAttestor(baseURL: URL(string: "https://api.snapceipt.cc")!, deviceId: "dev-1")
        let h = await a.headers(forBody: Data("{}".utf8))
        XCTAssertTrue(h.isEmpty, "Expected no attest headers on the Simulator (fail-open), got: \(h)")
    }
}
