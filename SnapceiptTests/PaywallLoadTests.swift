import Testing
@testable import Snapceipt

/// Integration check for the "Snapceipt Pro plans don't load" bug at the load→state
/// boundary. Drives the REAL `StoreKitService.loadProducts()` with an injected fetch so
/// the outcome is deterministic — StoreKit's `Product` has no public initializer and
/// `SKTestSession` fails on this CI (SKInternalErrorDomain 3), so real products can't be
/// produced in a test here.
///
/// The regression: a successful-but-EMPTY response (App Store Connect not vending) and a
/// THROWN error were both swallowed into an empty array that the paywall rendered as a
/// forever-spinner. These pin each outcome to its own state, so PaywallView shows a
/// Retry affordance instead of an endless spinner.
@Suite("Paywall product loading")
@MainActor
struct PaywallLoadTests {
    @Test("a successful-but-empty load lands in .empty, not stuck loading")
    func emptyLoadIsEmpty() async {
        let service = StoreKitService()
        service.fetchProducts = { [] }
        await service.loadProducts()
        #expect(service.productsState == .empty)
        #expect(service.products.isEmpty)
    }

    @Test("a thrown StoreKit error lands in .failed, not swallowed")
    func erroredLoadIsFailed() async {
        struct StoreDown: Error {}
        let service = StoreKitService()
        service.fetchProducts = { throw StoreDown() }
        await service.loadProducts()
        guard case .failed = service.productsState else {
            Issue.record("expected .failed, got \(service.productsState)")
            return
        }
    }
}
