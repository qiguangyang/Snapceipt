import Testing
import Foundation
@testable import Snapceipt

@Suite("BasLocalStore")
struct BasLocalStoreTests {
    private func store() -> BasLocalStore {
        BasLocalStore(defaults: UserDefaults(suiteName: "sc.test.bas.\(UUID().uuidString)")!)
    }

    @Test("payg persists per profile+period and defaults to 0")
    func payg() {
        let s = store()
        #expect(s.paygInstalmentCents(profileId: "p1", periodKey: "2025Q4") == 0)
        s.setPaygInstalmentCents(25_000, profileId: "p1", periodKey: "2025Q4")
        #expect(s.paygInstalmentCents(profileId: "p1", periodKey: "2025Q4") == 25_000)
        // Different period is independent.
        #expect(s.paygInstalmentCents(profileId: "p1", periodKey: "2025Q3") == 0)
    }

    @Test("mark-as-lodged stores a snapshot and reports drift")
    func lodged() {
        let s = store()
        #expect(s.lodgedSnapshot(profileId: "p1", periodKey: "2025Q4") == nil)
        let snap = BasLocalStore.Snapshot(g1: 1_100_000, oneA: 100_000, oneB: 30_000,
                                          netGst: 70_000, payg: 0, total: 70_000, lodgedAtMs: 123)
        s.markLodged(snap, profileId: "p1", periodKey: "2025Q4")
        let read = s.lodgedSnapshot(profileId: "p1", periodKey: "2025Q4")
        #expect(read?.oneA == 100_000)
        #expect(read?.lodgedAtMs == 123)
        // Drift detection: a later recompute differing from the snapshot flags changed.
        #expect(s.hasDrifted(current: BasLocalStore.Snapshot(g1: 1_100_000, oneA: 100_000,
                 oneB: 30_000, netGst: 70_000, payg: 0, total: 70_000, lodgedAtMs: 999),
                 profileId: "p1", periodKey: "2025Q4") == false)
        #expect(s.hasDrifted(current: BasLocalStore.Snapshot(g1: 1_100_000, oneA: 99_000,
                 oneB: 30_000, netGst: 69_000, payg: 0, total: 69_000, lodgedAtMs: 999),
                 profileId: "p1", periodKey: "2025Q4") == true)
    }
}
