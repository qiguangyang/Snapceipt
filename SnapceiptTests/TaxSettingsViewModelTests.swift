import Testing
import Foundation
import SwiftData
@testable import Snapceipt

@MainActor
@Suite("TaxSettingsViewModel")
struct TaxSettingsViewModelTests {
    private func fixture(type: String) throws -> (ModelContext, MockSyncEngine, Profile) {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        let ctx = ModelContext(container)
        let p = Profile(userId: "u1", name: "P", type: type, accent1: "#0", accent2: "#1", accent3: "#2")
        ctx.insert(p)
        ctx.insert(TaxSettings(userId: "u1", profileId: p.id))
        try ctx.save()
        return (ctx, MockSyncEngine(), p)
    }

    @Test("loads the row and persists an edited meals % via enqueue")
    func editMeals() throws {
        let (ctx, sync, p) = try fixture(type: "business")
        let vm = TaxSettingsViewModel(context: ctx, sync: sync, userId: "u1", profile: p, api: MockAPIClient())
        #expect(vm.mealsDeductiblePct == 50)
        vm.setMealsDeductiblePct(80)
        #expect(vm.mealsDeductiblePct == 80)
        let pid = p.id
        let row = try ctx.fetch(FetchDescriptor<TaxSettings>(predicate: #Predicate { $0.profileId == pid })).first!
        #expect(row.mealsDeductiblePct == 80)
        #expect(sync.calls.last?.entityType == .taxSettings)
        #expect(sync.calls.last?.op == "upsert")
    }

    @Test("business shows identity; personal hides it")
    func identityVisibility() throws {
        let (ctx, sync, biz) = try fixture(type: "business")
        #expect(TaxSettingsViewModel(context: ctx, sync: sync, userId: "u1", profile: biz, api: MockAPIClient()).showsBusinessIdentity == true)
        let p = Profile(userId: "u1", name: "Personal", type: "personal", accent1: "#0", accent2: "#1", accent3: "#2")
        ctx.insert(p); ctx.insert(TaxSettings(userId: "u1", profileId: p.id)); try ctx.save()
        #expect(TaxSettingsViewModel(context: ctx, sync: sync, userId: "u1", profile: p, api: MockAPIClient()).showsBusinessIdentity == false)
    }

    @Test("editing GST + ABN writes to the Profile and FY start to tax_settings")
    func gstAndFy() throws {
        let (ctx, sync, p) = try fixture(type: "business")
        let vm = TaxSettingsViewModel(context: ctx, sync: sync, userId: "u1", profile: p, api: MockAPIClient())
        vm.setGstRegistered(true)
        vm.setAbn("12 345 678 901")
        vm.setFinancialYearStartMonth(4)
        #expect(p.gstRegistered == true)
        #expect(p.abn == "12 345 678 901")
        let pid = p.id
        let row = try ctx.fetch(FetchDescriptor<TaxSettings>(predicate: #Predicate { $0.profileId == pid })).first!
        #expect(row.financialYearStartMonth == 4)
        // both a profile upsert and a taxSettings upsert were enqueued
        #expect(sync.calls.contains { $0.entityType == .profile })
        #expect(sync.calls.contains { $0.entityType == .taxSettings })
    }
}
