import Testing
@testable import Snapceipt

@Suite("Pro feature gate")
struct ProGateTests {
    @Test("free plan locks every Pro feature")
    func freeLocks() {
        let gate = ProGate(plan: "free")
        #expect(gate.isPro == false)
        #expect(gate.allows(.basExport) == false)
        #expect(gate.allows(.quotes) == false)
        #expect(gate.allows(.logbooks) == false)
        #expect(gate.allows(.emailIn) == false)
    }

    @Test("pro plan unlocks every Pro feature")
    func proUnlocks() {
        let gate = ProGate(plan: "pro")
        #expect(gate.isPro == true)
        #expect(gate.allows(.basExport) == true)
        #expect(gate.allows(.quotes) == true)
        #expect(gate.allows(.logbooks) == true)
        #expect(gate.allows(.emailIn) == true)
    }

    @Test("unknown / nil plan is treated as free (fail closed)")
    func unknownIsFree() {
        #expect(ProGate(plan: nil).isPro == false)
        #expect(ProGate(plan: "enterprise").allows(.quotes) == false)
    }
}
