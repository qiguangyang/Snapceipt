import Testing
@testable import Snapceipt

@Suite("Smoke")
struct SmokeTests {
    @Test("test harness runs")
    func harnessRuns() {
        #expect(Bool(true))
    }

    @Test("app module is importable and the SwiftData container builds")
    func containerBuilds() {
        let container = makeSnapceiptContainer(inMemory: true)
        #expect(container.configurations.isEmpty == false)
    }
}
