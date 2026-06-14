import Testing
@testable import Snapceipt

@Suite("StoreKit service mapping")
@MainActor
struct StoreKitServiceTests {
    @Test("known product ids map to plan periods")
    func productIds() {
        #expect(StoreKitService.ProductID.monthly == "app.snapceipt.pro.monthly")
        #expect(StoreKitService.ProductID.yearly  == "app.snapceipt.pro.yearly")
        #expect(StoreKitService.ProductID.all == ["app.snapceipt.pro.monthly",
                                                  "app.snapceipt.pro.yearly"])
    }

    @Test("a pro product id is recognised as entitling")
    func entitlingIds() {
        #expect(StoreKitService.isProProduct("app.snapceipt.pro.monthly") == true)
        #expect(StoreKitService.isProProduct("app.snapceipt.pro.yearly") == true)
        #expect(StoreKitService.isProProduct("app.snapceipt.something.else") == false)
    }

    @Test("purchase outcomes map to a stable result enum")
    func outcomeMapping() {
        #expect(StoreKitService.PurchaseOutcome.success.entitled == true)
        #expect(StoreKitService.PurchaseOutcome.userCancelled.entitled == false)
        #expect(StoreKitService.PurchaseOutcome.pending.entitled == false)
        #expect(StoreKitService.PurchaseOutcome.failed.entitled == false)
    }
}
