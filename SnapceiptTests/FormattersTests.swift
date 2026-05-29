import Testing
@testable import Snapceipt

@Suite("Formatters")
struct FormattersTests {

    // fmt(-4250) == "−$42.50"  (leading character is U+2212 MINUS SIGN, not hyphen)
    @Test func negativeUsesUnicodeMinusAndCents() {
        let result = fmt(-4250)
        #expect(result == "\u{2212}$42.50")
        // Guard against an accidental ASCII hyphen regression.
        #expect(result.first == "\u{2212}")
        #expect(!result.contains("-"))
    }

    // fmt(420000, showCents: false) == "$4,200"  (grouped thousands, no decimals)
    @Test func showCentsFalseDropsDecimalsAndGroups() {
        #expect(fmt(420000, showCents: false) == "$4,200")
    }

    // fmt(85000, sign: true) == "+$850.00"  (explicit + for positives when sign)
    @Test func signTruePrefixesPlusForPositive() {
        #expect(fmt(85000, sign: true) == "+$850.00")
    }

    // Default positive has no sign prefix.
    @Test func positiveNoSignByDefault() {
        #expect(fmt(85000) == "$850.00")
    }

    // Zero renders without a sign even when sign:true.
    @Test func zeroHasNoSign() {
        #expect(fmt(0, sign: true) == "$0.00")
        #expect(fmt(0) == "$0.00")
    }

    // fmtK(120000 cents == $1200) == "$1.2k"  (one decimal, under $10k)
    @Test func fmtKUnderTenThousandKeepsOneDecimal() {
        #expect(fmtK(120000) == "$1.2k")
    }

    // fmtK(1200000 cents == $12000) == "$12k"  (integer k at >= $10000)
    @Test func fmtKAtTenThousandDropsDecimal() {
        #expect(fmtK(1200000) == "$12k")
    }

    // fmtK under $1000 falls back to a plain integer dollar string.
    @Test func fmtKUnderThousandNoK() {
        #expect(fmtK(50000) == "$500")
    }

    // fmtDate("2026-05-28") == "28 May"  (en-AU day + short month, no leading zero)
    @Test func fmtDateDayShortMonth() {
        #expect(fmtDate("2026-05-28") == "28 May")
    }

    // fmtDate long style includes the year.
    @Test func fmtDateLongStyleIncludesYear() {
        #expect(fmtDate("2026-05-28", style: .long) == "28 May 2026")
    }
}
