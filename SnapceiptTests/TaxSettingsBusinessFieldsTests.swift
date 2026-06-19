import Foundation
import SwiftData
import UIKit
import Testing
@testable import Snapceipt

@MainActor
@Suite("TaxSettings business fields + GST rate")
struct TaxSettingsBusinessFieldsTests {
    /// No-op enqueuer (this suite asserts on the Profile/VM, not sync side effects).
    final class NoopSync: SyncEnqueuing {
        func enqueue(op: String, entityType: EntityType, entity: any Syncable) {}
    }

    private func makeVM() throws -> (TaxSettingsViewModel, Profile, MockAPIClient) {
        let c = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        let p = Profile(userId: "u1", name: "Biz", type: "business",
                        accent1: "#0E7C72", accent2: "#DCF0ED", accent3: "#0A5950")
        p.id = "p1"
        c.insert(p); try c.save()
        let mock = MockAPIClient()
        let vm = TaxSettingsViewModel(context: c, sync: NoopSync(), userId: "u1", profile: p, api: mock)
        return (vm, p, mock)
    }

    @Test("preset NZ sets 1500; AU sets 1000")
    func presets() throws {
        let (vm, p, _) = try makeVM()
        vm.setGstRatePreset(.nz)
        #expect(vm.gstRateBp == 1500)
        #expect(p.gstRateBp == 1500)
        vm.setGstRatePreset(.au)
        #expect(vm.gstRateBp == 1000)
        #expect(p.gstRateBp == 1000)
    }

    @Test("custom 12.5% → 1250 bp; preset reads back as .custom")
    func custom() throws {
        let (vm, p, _) = try makeVM()
        vm.setCustomGstPercent(12.5)
        #expect(vm.gstRateBp == 1250)
        #expect(p.gstRateBp == 1250)
        #expect(vm.gstRatePreset == .custom)
    }

    @Test("preset derives from existing rate: 1000→.au, 1500→.nz, else .custom")
    func presetDerivation() throws {
        let (vm, p, _) = try makeVM()
        p.gstRateBp = 1500; vm.setGstRateBp(1500); #expect(vm.derivedPreset == .nz)
        p.gstRateBp = 1000; vm.setGstRateBp(1000); #expect(vm.derivedPreset == .au)
        p.gstRateBp = 1250; vm.setGstRateBp(1250); #expect(vm.derivedPreset == .custom)
    }

    @Test("business field setters persist + normalize blank to nil")
    func businessFields() throws {
        let (vm, p, _) = try makeVM()
        vm.setBusinessEmail("hi@biz.au")
        vm.setPhone("0400")
        vm.setWebsite("biz.au")
        vm.setAddressText("1 St\nSydney")
        vm.setBankDetails("BSB 000-000\nAcct 1")
        #expect(p.businessEmail == "hi@biz.au")
        #expect(p.phone == "0400")
        #expect(p.website == "biz.au")
        #expect(p.addressText == "1 St\nSydney")
        #expect(p.bankDetails == "BSB 000-000\nAcct 1")
        vm.setBusinessEmail("   ")
        #expect(p.businessEmail == nil)
    }

    @Test("uploadLogo reduces + uploads + stores key")
    func logo() async throws {
        let (vm, p, mock) = try makeVM()
        mock.uploadProfileLogoHandler = { pid, _ in
            UploadProfileLogoResponse(logoR2Key: "\(pid)/profiles/p1/logo")
        }
        let img = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        await vm.uploadLogo(img)
        #expect(mock.uploadProfileLogoCalls.count == 1)
        #expect(mock.uploadProfileLogoCalls[0].profileId == "p1")
        #expect(vm.logoR2Key == "p1/profiles/p1/logo")
        #expect(p.logoR2Key == "p1/profiles/p1/logo")
    }
}
