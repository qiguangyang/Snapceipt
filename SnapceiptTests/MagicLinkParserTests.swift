import Testing
import Foundation
@testable import Snapceipt

@Suite("MagicLinkParser")
struct MagicLinkParserTests {
    @Test("extracts token from the custom-scheme deep link")
    func customScheme() throws {
        let url = try #require(URL(string: "snapceipt://auth/verify?token=abc123"))
        #expect(MagicLinkParser.token(from: url) == "abc123")
    }

    @Test("extracts token from the universal link path /auth/verify")
    func universalLink() throws {
        let url = try #require(URL(string: "https://snapceipt.app/auth/verify?token=xyz-789_QQ"))
        #expect(MagicLinkParser.token(from: url) == "xyz-789_QQ")
    }

    @Test("also accepts the backend /auth/magic universal-link path")
    func magicPath() throws {
        let url = try #require(URL(string: "https://snapceipt.app/auth/magic?token=tok42"))
        #expect(MagicLinkParser.token(from: url) == "tok42")
    }

    @Test("percent-decodes the token value")
    func percentDecoded() throws {
        let url = try #require(URL(string: "snapceipt://auth/verify?token=a%2Bb%3Dc"))
        #expect(MagicLinkParser.token(from: url) == "a+b=c")
    }

    @Test("returns nil for an unrelated path")
    func unrelatedPath() throws {
        let url = try #require(URL(string: "https://snapceipt.app/blog?token=nope"))
        #expect(MagicLinkParser.token(from: url) == nil)
    }

    @Test("returns nil when the token query item is missing")
    func missingToken() throws {
        let url = try #require(URL(string: "snapceipt://auth/verify"))
        #expect(MagicLinkParser.token(from: url) == nil)
    }

    @Test("returns nil for an empty token")
    func emptyToken() throws {
        let url = try #require(URL(string: "snapceipt://auth/verify?token="))
        #expect(MagicLinkParser.token(from: url) == nil)
    }
}
