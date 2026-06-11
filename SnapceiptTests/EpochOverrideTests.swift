import XCTest
@testable import Snapceipt

final class EpochOverrideTests: XCTestCase {
    override func tearDown() { Epoch.override = nil; super.tearDown() }

    func test_nowMs_usesOverrideWhenSet() {
        Epoch.override = 1_700_000_000_000   // fixed ms
        XCTAssertEqual(Epoch.nowMs(), 1_700_000_000_000)
    }

    func test_now_returnsOverrideAsDate() {
        Epoch.override = 1_700_000_000_000
        XCTAssertEqual(Epoch.now().timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
    }

    func test_nowMs_fallsBackToWallClockWhenNil() {
        Epoch.override = nil
        let before = Int(Date().timeIntervalSince1970 * 1000) - 1000
        XCTAssertGreaterThan(Epoch.nowMs(), before)
    }
}
