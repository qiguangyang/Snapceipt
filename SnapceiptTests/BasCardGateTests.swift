import Testing
@testable import Snapceipt

@Suite("BAS card gate")
struct BasCardGateTests {
    @Test("card shows only for business + gstRegistered")
    func gate() {
        #expect(ReportsView.showsBasCard(profileType: "business", gstRegistered: true) == true)
        #expect(ReportsView.showsBasCard(profileType: "business", gstRegistered: false) == false)
        #expect(ReportsView.showsBasCard(profileType: "personal", gstRegistered: true) == false)
        #expect(ReportsView.showsBasCard(profileType: "personal", gstRegistered: false) == false)
    }
}
