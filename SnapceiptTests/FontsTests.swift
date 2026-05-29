import Testing
import UIKit
@testable import Snapceipt

struct FontsTests {
    @Test func familyNameConstantsAreExact() {
        #expect(Typeface.display == "Schibsted Grotesk")
        #expect(Typeface.ui == "Hanken Grotesk")
    }

    @Test func bundledFamiliesAreRegistered() {
        // UIFont sees app-bundled fonts (UIAppFonts) at runtime in the test host.
        let families = Set(UIFont.familyNames)
        #expect(families.contains(Typeface.display))
        #expect(families.contains(Typeface.ui))
    }
}
