import Testing
import Foundation
@testable import Snapceipt

/// The plan-based Cloud AI default + the usage-cap auto-off (`AppSettings`). `UserDefaults.standard`
/// is shared, so each test clears the two keys first. `isOnDeviceAIAvailable` is a compile-once
/// static, so the Free default is asserted against it rather than a hardcoded value.
struct AppSettingsSmartScanTests {
    private func reset() {
        UserDefaults.standard.removeObject(forKey: AppSettings.smartScanEnabledKey)
        UserDefaults.standard.removeObject(forKey: AppSettings.smartScanUserSetKey)
    }

    @Test("Pro defaults to Cloud AI ON")
    func proDefaultsOn() {
        reset()
        AppSettings.applyPlanDefaultSmartScan(isPro: true)
        #expect(AppSettings.smartScanEnabled == true)
    }

    @Test("Free defaults to on-device (Cloud OFF) when on-device AI is available")
    func freeDefaultsOff() {
        reset()
        AppSettings.applyPlanDefaultSmartScan(isPro: false)
        // Free → OFF on an FM device; a device without on-device AI still gets Cloud (else no AI).
        #expect(AppSettings.smartScanEnabled == !AppSettings.isOnDeviceAIAvailable)
    }

    @Test("an upgrade defaults an unpinned toggle to Cloud ON")
    func upgradeDefaultsOn() {
        reset()
        AppSettings.applyPlanDefaultSmartScan(isPro: false)   // Free
        AppSettings.applyPlanDefaultSmartScan(isPro: true)    // upgrade → Pro
        #expect(AppSettings.smartScanEnabled == true)
    }

    @Test("a pinned (user-chosen) toggle is never overridden by the plan default")
    func pinnedChoiceWins() {
        reset()
        AppSettings.smartScanEnabled = false   // user turned Cloud OFF
        AppSettings.pinSmartScan()
        AppSettings.applyPlanDefaultSmartScan(isPro: true)    // Pro would default ON…
        #expect(AppSettings.smartScanEnabled == false)        // …but the explicit choice wins
    }

    @Test("hitting the usage cap auto-disables Cloud AI and pins it off")
    func capAutoDisables() {
        reset()
        AppSettings.smartScanEnabled = true
        AppSettings.disableSmartScanOnCap()
        #expect(AppSettings.smartScanEnabled == false)
        #expect(AppSettings.smartScanUserPinned == true)
        // Pinned off by the cap → not even a Pro default turns it back on automatically.
        AppSettings.applyPlanDefaultSmartScan(isPro: true)
        #expect(AppSettings.smartScanEnabled == false)
    }
}
