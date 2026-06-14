import Testing
@testable import Snapceipt

@Suite("AccessibilityID legal ids")
struct AccessibilityIDLegalTests {
    @Test("Profile Legal row id exists with a stable string value")
    func legalRowId() {
        #expect(AccessibilityID.profileRowLegal == "profile.row.legal")
    }
}
