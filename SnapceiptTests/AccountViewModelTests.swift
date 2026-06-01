import Testing
import Foundation
@testable import Snapceipt

@MainActor
@Suite("AccountViewModel")
struct AccountViewModelTests {
    private func vm(_ api: MockAPIClient) -> (AccountViewModel, AuthStore, Box) {
        let auth = AuthStore(keychain: Keychain(service: "test.\(UUID().uuidString)"))
        auth.save(SessionResponse(accessToken: "a", refreshToken: "r", expiresIn: 900,
                                  user: SessionUser(id: "u1", email: "old@e.com", displayName: "You")))
        let box = Box()
        let model = AccountViewModel(api: api, auth: auth, currentDeviceId: "thisDevice", onSignedOut: { box.signedOut = true })
        return (model, auth, box)
    }
    final class Box { var signedOut = false }

    @Test("change email: request then verify updates the session email")
    func changeEmail() async throws {
        let api = MockAPIClient()
        api.requestEmailChangeHandler = { EmailChangeRequested(sent: true, devCode: "000000") }
        api.verifyEmailChangeHandler = { _ in AccountUser(id: "u1", email: "new@e.com", displayName: "You", plan: "free") }
        let (m, auth, _) = vm(api)
        m.newEmail = "new@e.com"
        await m.requestCode()
        #expect(m.codeSent == true)
        m.code = "000000"
        await m.verifyCode()
        #expect(m.codeSent == false)
        #expect(auth.session?.email == "new@e.com")
        #expect(api.verifyEmailChangeCalls == ["000000"])
    }

    @Test("loadDevices populates from me()")
    func devices() async throws {
        let api = MockAPIClient()
        api.meHandler = { MeResponse(user: SessionUser(id: "u1", email: "old@e.com", displayName: "You"),
                                     devices: [DeviceDTO(id: "thisDevice"), DeviceDTO(id: "other")]) }
        let (m, _, _) = vm(api)
        await m.loadDevices()
        #expect(m.devices.count == 2)
    }

    @Test("revoking a non-current device reloads; revoking current signs out")
    func revoke() async throws {
        let api = MockAPIClient()
        api.meHandler = { MeResponse(user: SessionUser(id: "u1", email: "old@e.com", displayName: "You"), devices: [DeviceDTO(id: "other")]) }
        let (m, _, box) = vm(api)
        await m.revoke("other")
        #expect(api.revokeDeviceCalls == ["other"])
        #expect(box.signedOut == false)
        await m.revoke("thisDevice")
        #expect(box.signedOut == true)
    }

    @Test("deleteAccount clears the session and signs out")
    func delete() async throws {
        let api = MockAPIClient()
        let (m, auth, box) = vm(api)
        await m.deleteAccount()
        #expect(api.deleteAccountCallCount == 1)
        #expect(auth.session == nil)
        #expect(box.signedOut == true)
    }
}
