import Testing
import Foundation
import SwiftData
@testable import Snapceipt

@MainActor
@Suite("SmartRulesViewModel")
struct SmartRulesViewModelTests {
    private func fixture() throws -> (ModelContext, MockSyncEngine) {
        let c = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        return (ModelContext(c), MockSyncEngine())
    }

    @Test("create inserts a profile-scoped rule and enqueues upsert")
    func create() throws {
        let (ctx, sync) = try fixture()
        let vm = SmartRulesViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1")
        let r = vm.create(matchType: "merchant_contains", matcher: "uber", categoryId: nil, setDeductiblePct: 100, setMode: "business")
        #expect(vm.rules.count == 1)
        #expect(r.profileId == "p1")
        #expect(r.matcher == "uber")
        #expect(sync.calls.last?.entityType == .smartRule)
        #expect(sync.calls.last?.op == "upsert")
    }

    @Test("update + delete enqueue accordingly")
    func updateDelete() throws {
        let (ctx, sync) = try fixture()
        let vm = SmartRulesViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1")
        let r = vm.create(matchType: "merchant_equals", matcher: "X", categoryId: nil, setDeductiblePct: nil, setMode: nil)
        vm.update(r) { $0.enabled = false; $0.priority = 5 }
        #expect(r.enabled == false)
        #expect(r.priority == 5)
        #expect(sync.calls.last?.op == "upsert")
        vm.delete(r)
        #expect(vm.rules.isEmpty)
        #expect(sync.calls.last?.op == "delete")
    }
}
