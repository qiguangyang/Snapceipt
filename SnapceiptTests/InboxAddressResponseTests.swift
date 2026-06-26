import Testing
import Foundation
@testable import Snapceipt

@Suite("InboxAddressResponse")
struct InboxAddressResponseTests {
    @Test("decodes the backend payload")
    func decodes() throws {
        let json = #"{"profileId":"p1","token":"abc123","address":"r.abc123@in.snapceipt.cc"}"#
        let res = try JSONDecoder().decode(InboxAddressResponse.self, from: Data(json.utf8))
        #expect(res.profileId == "p1")
        #expect(res.token == "abc123")
        #expect(res.address == "r.abc123@in.snapceipt.cc")
    }

    @MainActor
    @Test("MockAPIClient records profileInbox calls")
    func mockRecords() async throws {
        let mock = MockAPIClient()
        mock.profileInboxHandler = { pid in
            InboxAddressResponse(profileId: pid, token: "t1", address: "r.t1@in.snapceipt.cc")
        }
        let a = try await mock.profileInbox(profileId: "p9")
        #expect(a.token == "t1")
        #expect(mock.profileInboxCalls == ["p9"])
    }
}
