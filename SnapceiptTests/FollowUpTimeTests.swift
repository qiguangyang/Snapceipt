import Testing
import Foundation
@testable import Snapceipt

@Suite("FollowUpTime")
struct FollowUpTimeTests {
    @Test func rejectsMissingSydneyClockTime() {
        #expect(throws: (any Error).self) {
            try FollowUpTime.resolve(components: DateComponents(year: 2026, month: 10, day: 4, hour: 2, minute: 30), timezone: "Australia/Sydney")
        }
    }
    @Test func ambiguousSydneyTimeUsesFirstOccurrence() throws {
        let r = try FollowUpTime.resolve(components: DateComponents(year: 2027, month: 4, day: 4, hour: 2, minute: 30), timezone: "Australia/Sydney")
        #expect(r.instant == ISO8601DateFormatter().date(from: "2027-04-03T15:30:00Z"))
        #expect(r.isAmbiguous && r.offsetSeconds == 39600)
    }
    @Test func rejectsInvalidZoneAndCalendarDate() {
        for (c, z) in [(DateComponents(year: 2026, month: 2, day: 30, hour: 9, minute: 0), "UTC"), (DateComponents(year: 2026, month: 10, day: 2, hour: 9, minute: 0), "Invalid/Zone")] {
            #expect(throws: (any Error).self) { try FollowUpTime.resolve(components: c, timezone: z) }
        }
    }
}
