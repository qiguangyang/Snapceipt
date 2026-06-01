import Testing
import Foundation
@testable import Snapceipt

@Suite("Account DTOs + APIClient")
struct AccountDTOTests {
    @Test("EmailChangeRequested + AccountUser decode")
    func decode() throws {
        let r = try JSONDecoder().decode(EmailChangeRequested.self, from: Data(#"{"sent":true,"devCode":"123456"}"#.utf8))
        #expect(r.sent == true); #expect(r.devCode == "123456")
        let wrap = try JSONDecoder().decode(AccountUserResponse.self, from: Data(#"{"user":{"id":"u","email":"new@e.com","displayName":"You","plan":"free"}}"#.utf8))
        #expect(wrap.user.email == "new@e.com"); #expect(wrap.user.plan == "free")
    }

    @Test("rich DeviceDTO decodes the /auth/me device fields")
    func device() throws {
        let json = #"{"id":"d1","platform":"ios","model":"iPhone","osVersion":"18.0","hasApnsToken":true,"pushEnabled":true,"lastSeenAt":123,"createdAt":1}"#
        let d = try JSONDecoder().decode(DeviceDTO.self, from: Data(json.utf8))
        #expect(d.id == "d1"); #expect(d.model == "iPhone"); #expect(d.pushEnabled == true)
    }

    @MainActor
    @Test("MockAPIClient records the 4 account calls")
    func mock() async throws {
        let m = MockAPIClient()
        m.requestEmailChangeHandler = { EmailChangeRequested(sent: true, devCode: "000000") }
        m.verifyEmailChangeHandler = { _ in AccountUser(id: "u", email: "n@e.com", displayName: "Y", plan: "free") }
        _ = try await m.requestEmailChange(newEmail: "n@e.com")
        _ = try await m.verifyEmailChange(code: "000000")
        try await m.revokeDevice(id: "d1")
        try await m.deleteAccount()
        #expect(m.requestEmailChangeCalls == ["n@e.com"])
        #expect(m.verifyEmailChangeCalls == ["000000"])
        #expect(m.revokeDeviceCalls == ["d1"])
        #expect(m.deleteAccountCallCount == 1)
    }
}
