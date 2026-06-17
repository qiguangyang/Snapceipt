import Testing
import Foundation
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

    // MARK: - Products load-state mapping
    //
    // The bug: a load that SUCCEEDS but returns zero products (App Store Connect
    // not vending — Paid Apps agreement inactive / subscriptions not "Ready to
    // Submit") was indistinguishable from "still loading", so the paywall span
    // forever. These pin the seam that now separates empty-success from a throw.

    @Test("an empty successful load maps to .empty (ASC misconfig), not loading")
    func emptyLoadMapsToEmpty() {
        #expect(StoreKitService.productsState(loaded: [], error: nil) == .empty)
    }

    @Test("a thrown error maps to .failed with a non-empty diagnostic")
    func errorMapsToFailed() {
        struct Boom: Error {}
        guard case .failed(let msg) = StoreKitService.productsState(loaded: nil, error: Boom()) else {
            Issue.record("expected .failed"); return
        }
        #expect(!msg.isEmpty)
    }

    @Test("loadErrorMessage prefers LocalizedError.errorDescription")
    func errorMessagePrefersLocalized() {
        struct Described: LocalizedError { var errorDescription: String? { "no network" } }
        #expect(StoreKitService.loadErrorMessage(Described()) == "no network")
    }

    @Test("products are empty for every non-loaded state")
    func nonLoadedHasNoProducts() {
        #expect(StoreKitService.ProductsState.loading.products.isEmpty)
        #expect(StoreKitService.ProductsState.empty.products.isEmpty)
        #expect(StoreKitService.ProductsState.failed("x").products.isEmpty)
    }
}
