import Testing
@testable import Snapceipt

@Suite("EntitlementStore")
@MainActor
struct EntitlementStoreTests {
    @Test("starts free")
    func startsFree() {
        let store = EntitlementStore()
        #expect(store.plan == "free")
        #expect(store.isPro == false)
    }

    @Test("local StoreKit entitlement promotes to pro")
    func localPromotes() {
        let store = EntitlementStore()
        store.setLocalEntitled(true)
        #expect(store.plan == "pro")
        #expect(store.isPro == true)
    }

    @Test("backend pro plan promotes to pro even without a local txn")
    func backendPromotes() {
        let store = EntitlementStore()
        store.applyServerPlan("pro")
        #expect(store.isPro == true)
    }

    @Test("either source true => pro (union); both false => free")
    func union() {
        let store = EntitlementStore()
        store.setLocalEntitled(true)
        store.applyServerPlan("free")
        #expect(store.isPro == true)          // local still entitling

        store.setLocalEntitled(false)
        store.applyServerPlan("free")
        #expect(store.isPro == false)         // both sources free
    }

    @Test("unknown server plan value keeps plan as free (fail-closed)")
    func unknownServerPlanIsClosedFree() {
        let store = EntitlementStore()
        store.applyServerPlan("enterprise")
        #expect(store.isPro == false)         // unrecognised value must not grant Pro
        #expect(store.plan == "free")
    }
}
