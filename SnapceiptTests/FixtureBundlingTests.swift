import Foundation
import Testing
@testable import Snapceipt

/// A bundle anchor so `Bundle(for:)` resolves the TEST target's resource bundle
/// (not the host app). Shared by the engine test.
final class GoldenAnchor {}

@Suite("Golden fixture bundling")
struct FixtureBundlingTests {
    @Test("bas-golden.json is bundled into the test target")
    func bundled() throws {
        let url = Bundle(for: GoldenAnchor.self).url(forResource: "bas-golden", withExtension: "json")
        guard let url else {
            Issue.record("bas-golden.json did NOT bundle into SnapceiptTests.xctest. Check the project.yml resources stanza for SnapceiptTests/Fixtures.")
            return
        }
        let data = try Data(contentsOf: url)
        #expect(data.count > 0)
        // The backend fixture keys its golden vectors under "scenarios" (byte-identical
        // copy of test/fixtures/bas-golden.json). Assert the real shape so this smoke
        // test proves the actual file bundled with content, not just any JSON object.
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect((obj?["scenarios"] as? [Any])?.count ?? 0 >= 5)
    }
}
