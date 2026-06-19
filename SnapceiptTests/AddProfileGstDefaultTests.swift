import Testing
@testable import Snapceipt

@Suite("AddProfile device-region GST default")
struct AddProfileGstDefaultTests {
    @Test("AU → 1000")
    func au() { #expect(AddProfileViewModel.defaultGstRateBp(regionCode: "AU") == 1000) }

    @Test("NZ → 1500")
    func nz() { #expect(AddProfileViewModel.defaultGstRateBp(regionCode: "NZ") == 1500) }

    @Test("other / nil → 1000")
    func other() {
        #expect(AddProfileViewModel.defaultGstRateBp(regionCode: "US") == 1000)
        #expect(AddProfileViewModel.defaultGstRateBp(regionCode: nil) == 1000)
    }
}
