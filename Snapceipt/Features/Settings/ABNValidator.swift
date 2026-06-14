import Foundation

/// Offline ATO ABN checksum (modulus-89): strip non-digits; require 11 digits;
/// subtract 1 from the first digit; multiply by weights [10,1,3,5,7,9,11,13,15,17,19];
/// sum; valid iff sum % 89 == 0. No network lookup in v1 (spec §4.6/§8).
enum ABNValidator {
    private static let weights = [10, 1, 3, 5, 7, 9, 11, 13, 15, 17, 19]

    static func isValid(_ raw: String) -> Bool {
        let digits = raw.filter(\.isNumber)
        guard digits.count == 11 else { return false }
        var nums = digits.compactMap { $0.wholeNumberValue }
        guard nums.count == 11 else { return false }
        nums[0] -= 1
        let sum = zip(nums, weights).reduce(0) { $0 + $1.0 * $1.1 }
        return sum % 89 == 0
    }

    /// Non-blocking hint predicate: an EMPTY/whitespace field is not "invalid"
    /// (it is simply unset); a non-empty field that fails the checksum is.
    static func looksInvalid(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        return !isValid(trimmed)
    }
}
