import Testing
import Foundation
@testable import Snapceipt

@Suite("UpdateDevice payload")
struct UpdateDevicePayloadTests {
    @Test("UpdateDeviceBody encodes only the provided optional fields (camelCase)")
    func encodesProvidedFields() throws {
        let body = UpdateDeviceBody(apnsToken: "deadbeef", quietHoursStartMin: 1320,
                                    quietHoursEndMin: 420, timezone: "Australia/Sydney",
                                    pushEnabled: true)
        let data = try JSONEncoder().encode(body)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["apnsToken"] as? String == "deadbeef")
        #expect(obj["quietHoursStartMin"] as? Int == 1320)
        #expect(obj["quietHoursEndMin"] as? Int == 420)
        #expect(obj["timezone"] as? String == "Australia/Sydney")
        #expect(obj["pushEnabled"] as? Bool == true)
    }

    @Test("nil optionals are omitted from the JSON")
    func omitsNils() throws {
        let body = UpdateDeviceBody(apnsToken: nil, quietHoursStartMin: nil,
                                    quietHoursEndMin: nil, timezone: "Australia/Perth",
                                    pushEnabled: nil)
        let data = try JSONEncoder().encode(body)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["timezone"] as? String == "Australia/Perth")
        #expect(obj["apnsToken"] == nil)
        #expect(obj["pushEnabled"] == nil)
    }

    @Test("MockAPIClient records the updateDevice call")
    func mockRecords() async throws {
        let mock = MockAPIClient()
        mock.updateDeviceHandler = { _ in UpdateDeviceResponse(id: "dev-1") }
        _ = try await mock.updateDevice(UpdateDeviceBody(
            apnsToken: "abc", quietHoursStartMin: nil, quietHoursEndMin: nil,
            timezone: "Australia/Sydney", pushEnabled: false))
        #expect(mock.updateDeviceCalls.count == 1)
        #expect(mock.updateDeviceCalls[0].apnsToken == "abc")
        #expect(mock.updateDeviceCalls[0].pushEnabled == false)
    }

    @Test("device token hex-encodes lowercased, no separators")
    func hexEncode() {
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01])
        #expect(NotificationDelegate.hexToken(data) == "deadbeef01")
        #expect(NotificationDelegate.hexToken(Data()) == "")
    }
}
