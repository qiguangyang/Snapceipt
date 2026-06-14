import Testing
@testable import Snapceipt

@MainActor
@Suite("Router .bas overlay")
struct RouterBasTests {
    @Test("presenting .bas sets the overlay with a stable id")
    func present() {
        let r = Router()
        r.present(.bas)
        #expect(r.overlay == .bas)
        #expect(r.overlay?.id == "bas")
        r.dismissOverlay()
        #expect(r.overlay == nil)
    }
}
