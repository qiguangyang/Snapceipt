import Testing
@testable import Snapceipt

struct AppLaunchTests {
    @Test func parsesStubAndResetFlags() {
        let l = AppLaunch(arguments: ["app", "-uiTestStub", "-uiTestReset"], environment: [:])
        #expect(l.useStub); #expect(l.reset); #expect(l.apiBaseURLOverride == nil)
    }
    @Test func parsesApiBaseURLOverride() {
        let l = AppLaunch(arguments: ["app"], environment: ["API_BASE_URL": "http://127.0.0.1:8787"])
        #expect(!l.useStub); #expect(l.apiBaseURLOverride?.absoluteString == "http://127.0.0.1:8787")
    }
    @Test func stubClientSignsInDevAccount() async throws {
        let s = StubAPIClient()
        let token = try await s.magicLinkRequestDev(email: DevAccount.email)
        #expect(token != nil)
        let session = try await s.magicLinkVerify(token: token!)
        #expect(session.user.id == DevAccount.userId)
    }
}
