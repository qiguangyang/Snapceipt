import Foundation
import CryptoKit
import Testing
@testable import Snapceipt

/// A bundle anchor so `Bundle(for:)` resolves the TEST target's resource bundle
/// (not the host app). Shared by the engine test.
final class GoldenAnchor {}

@Suite("Golden fixture bundling")
struct FixtureBundlingTests {
    @Test("Authentic v1 disk store and provenance are bundled")
    func v1StoreBundled() throws {
        let bundle = Bundle(for: GoldenAnchor.self)
        let store = try #require(bundle.url(forResource: "v1-workspace", withExtension: "store"))
        let data = try Data(contentsOf: store)
        #expect(String(data: data.prefix(15), encoding: .utf8) == "SQLite format 3")
        let provenance = try #require(bundle.url(forResource: "v1-workspace.provenance", withExtension: "json"))
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: provenance)) as? [String: Any]
        #expect(metadata?["baselineCommit"] as? String == "e22d9952a1c7eccdca08e2e70976ddee0a59ccb0")
        #expect(metadata?["module"] as? String == "Snapceipt")
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(metadata?["storeSHA256"] as? String == hash)
    }
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
