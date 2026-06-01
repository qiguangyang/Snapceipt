import Testing
import Foundation
@testable import Snapceipt

@Suite("AppleNonce")
struct AppleNonceTests {
    @Test("make() returns a 32-char raw nonce from the allowed charset")
    func rawNonceShape() {
        let raw = AppleNonce.make()
        #expect(raw.count == 32)
        let allowed = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        #expect(raw.allSatisfy { allowed.contains($0) })
    }

    @Test("make() returns unique values across calls")
    func rawNonceUnique() {
        var seen = Set<String>()
        for _ in 0..<500 { seen.insert(AppleNonce.make()) }
        #expect(seen.count == 500)
    }

    @Test("sha256 produces a stable 64-char lowercase hex digest")
    func sha256Stable() {
        // SHA-256 of the ASCII string "abc" is a well-known fixed vector.
        let digest = AppleNonce.sha256("abc")
        #expect(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(digest.count == 64)
    }
}
