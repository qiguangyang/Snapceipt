import Testing
import Foundation
@testable import Snapceipt

@Suite("QuoteStatus bridge")
struct QuoteStatusTests {
    @Test("all six statuses round-trip through the raw String storage")
    func roundTrip() {
        for s in QuoteStatus.allCases {
            let q = Quote(userId: "u1", profileId: "p1", status: s.rawValue)
            #expect(q.statusValue == s)
        }
    }

    @Test("setting statusValue writes the raw string")
    func setter() {
        let q = Quote(userId: "u1", profileId: "p1")
        q.statusValue = .sent
        #expect(q.status == "sent")
        #expect(q.statusValue == .sent)
    }

    @Test("an unknown raw status reads back as nil")
    func unknownIsNil() {
        let q = Quote(userId: "u1", profileId: "p1", status: "garbage")
        #expect(q.statusValue == nil)
    }

    @Test("raw values match the D1 CHECK enum exactly")
    func rawValues() {
        #expect(QuoteStatus.draft.rawValue == "draft")
        #expect(QuoteStatus.sent.rawValue == "sent")
        #expect(QuoteStatus.accepted.rawValue == "accepted")
        #expect(QuoteStatus.declined.rawValue == "declined")
        #expect(QuoteStatus.expired.rawValue == "expired")
        #expect(QuoteStatus.invoiced.rawValue == "invoiced")
    }
}
