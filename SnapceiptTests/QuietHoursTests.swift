import Testing
import Foundation
@testable import Snapceipt

@Suite("QuietHours")
struct QuietHoursTests {
    @Test("minutes <-> components round-trip")
    func roundTrip() {
        #expect(QuietHours.minutes(hour: 22, minute: 0) == 1320)
        #expect(QuietHours.minutes(hour: 7, minute: 0) == 420)
        let c = QuietHours.components(fromMinutes: 1320)
        #expect(c.hour == 22 && c.minute == 0)
    }

    @Test("minutes clamps into 0...1439")
    func clamps() {
        #expect(QuietHours.minutes(hour: 25, minute: 0) == 1439)
        #expect(QuietHours.minutes(hour: -1, minute: -5) == 0)
    }

    @Test("payload carries push + quiet minutes + the device timezone")
    func payload() {
        let body = QuietHours.updateBody(pushEnabled: true, quietStartMin: 1320,
                                         quietEndMin: 420, timezone: "Australia/Sydney")
        #expect(body.pushEnabled == true)
        #expect(body.quietHoursStartMin == 1320)
        #expect(body.quietHoursEndMin == 420)
        #expect(body.timezone == "Australia/Sydney")
        #expect(body.apnsToken == nil)   // settings changes never send the token
    }

    @Test("disabling quiet hours sends null minutes (omitted) but keeps tz + push")
    func quietOff() {
        let body = QuietHours.updateBody(pushEnabled: false, quietStartMin: nil,
                                         quietEndMin: nil, timezone: "Australia/Perth")
        #expect(body.quietHoursStartMin == nil)
        #expect(body.quietHoursEndMin == nil)
        #expect(body.pushEnabled == false)
        #expect(body.timezone == "Australia/Perth")
    }
}

@MainActor
@Suite("NotificationsSettingsViewModel")
struct NotificationsSettingsViewModelTests {
    @Test("toggling push + setting quiet hours calls updateDevice with the right payload")
    func updatesDevice() async throws {
        let mock = MockAPIClient()
        mock.updateDeviceHandler = { _ in UpdateDeviceResponse(id: "d") }
        let suiteName = "sc.test.notif.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let vm = NotificationsSettingsViewModel(api: mock, defaults: defaults,
                                                timezone: "Australia/Sydney")
        vm.pushEnabled = true
        vm.quietHoursEnabled = true   // REQUIRED: persist() only sends the minutes when quiet hours are ON
        vm.quietStartMin = 1320
        vm.quietEndMin = 420
        await vm.persist()
        #expect(mock.updateDeviceCalls.count == 1)
        let body = mock.updateDeviceCalls[0]
        #expect(body.pushEnabled == true)
        #expect(body.quietHoursStartMin == 1320)
        #expect(body.quietHoursEndMin == 420)
        #expect(body.timezone == "Australia/Sydney")
        #expect(body.apnsToken == nil)
        defaults.removePersistentDomain(forName: suiteName)  // clean up by SUITE name, not .description
    }

    @Test("quiet hours off sends nil minutes")
    func quietOff() async throws {
        let mock = MockAPIClient()
        mock.updateDeviceHandler = { _ in UpdateDeviceResponse(id: "d") }
        let suiteName = "sc.test.notif.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let vm = NotificationsSettingsViewModel(api: mock, defaults: defaults,
                                                timezone: "Australia/Perth")
        vm.quietHoursEnabled = false
        await vm.persist()
        #expect(mock.updateDeviceCalls[0].quietHoursStartMin == nil)
        #expect(mock.updateDeviceCalls[0].quietHoursEndMin == nil)
        defaults.removePersistentDomain(forName: suiteName)  // clean up by SUITE name, not .description
    }
}
