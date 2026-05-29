import Testing
import Foundation
@testable import Snapceipt

@Suite("IDClock")
struct IDClockTests {
    @Test("uuidv7 is RFC-shaped: version 7 + variant 10xx")
    func shape() {
        let id = ID.uuidv7()
        // 8-4-4-4-12, version nibble = 7, variant nibble in 8/9/a/b.
        let pattern = "^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
        #expect(id.range(of: pattern, options: .regularExpression) != nil)
    }

    @Test("uuidv7 is unique across a large batch")
    func unique() {
        var seen = Set<String>()
        for _ in 0..<5000 { seen.insert(ID.uuidv7()) }
        #expect(seen.count == 5000)
    }

    @Test("uuidv7 is time-ordered: ids generated later sort >= earlier")
    func ordered() throws {
        let first = ID.uuidv7()
        // Force a later millisecond so the 48-bit prefix advances.
        Thread.sleep(forTimeInterval: 0.003)
        let second = ID.uuidv7()
        #expect(second > first)
    }

    @Test("nowMs returns integer ms close to wall clock")
    func nowMs() {
        let t = Clock.nowMs()
        let wall = Int((Date().timeIntervalSince1970 * 1000).rounded())
        #expect(abs(t - wall) < 1000)
    }
}
