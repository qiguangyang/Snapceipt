import Testing
@testable import Snapceipt

@Suite("ABNValidator modulus-89")
struct ABNValidatorTests {
    @Test("a known-valid ABN passes (ATO example 51 824 753 556)")
    func valid() {
        #expect(ABNValidator.isValid("51824753556") == true)
        #expect(ABNValidator.isValid("51 824 753 556") == true)   // spaces ignored
    }

    @Test("a one-digit-off ABN fails the checksum")
    func invalid() {
        #expect(ABNValidator.isValid("51824753557") == false)
    }

    @Test("wrong length or non-digits is invalid")
    func malformed() {
        #expect(ABNValidator.isValid("123") == false)
        #expect(ABNValidator.isValid("5182475355X") == false)
    }

    @Test("empty is treated as not-invalid (no hint shown)")
    func empty() {
        // Empty means "unset" — the field hint is non-blocking, so empty is NOT invalid.
        #expect(ABNValidator.looksInvalid("") == false)
        #expect(ABNValidator.looksInvalid("   ") == false)
        #expect(ABNValidator.looksInvalid("51824753557") == true)
    }
}
