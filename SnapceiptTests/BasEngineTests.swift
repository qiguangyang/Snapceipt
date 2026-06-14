import Testing
import Foundation
@testable import Snapceipt

@Suite("BasEngine")
struct BasEngineTests {
    private func txn(_ amount: Int, gstFree: Bool = false, capital: Bool = false,
                     date: String = "2026-04-15") -> BasEngine.Txn {
        BasEngine.Txn(amountCents: amount, gstFree: gstFree, capital: capital, txnDate: date)
    }

    @Test("canonical registered scenario matches the frozen §4.3 worked numbers")
    func canonical() {
        let r = BasEngine.compute(
            txns: [
                txn(1_100_000),                                  // taxable income
                txn(-110_000),                                   // taxable non-capital expense
                txn(-220_000, capital: true),                    // taxable capital (>$1,000 → G10)
                txn(-33_000, gstFree: true),                     // GST-free groceries
            ],
            gstRegistered: true,
            manual: BasEngine.Manual(paygInstalmentCents: 0))
        #expect(r.g1 == 1_100_000)
        #expect(r.g3 == 0)
        #expect(r.oneA == 100_000)
        #expect(r.g10 == 220_000)
        #expect(r.g11 == 143_000)   // (110_000 + 33_000) — capital removed from G11
        #expect(r.g14 == 33_000)
        #expect(r.g17 == 330_000)
        #expect(r.oneB == 30_000)
        #expect(r.netGstCents == 70_000)
        #expect(r.paygCents == 0)
        #expect(r.totalPayableCents == 70_000)
    }

    @Test("non-registered forces 1A = 0")
    func nonRegistered() {
        let r = BasEngine.compute(txns: [txn(1_100_000)], gstRegistered: false,
                                  manual: BasEngine.Manual(paygInstalmentCents: 0))
        #expect(r.oneA == 0)
        #expect(r.g1 == 1_100_000)   // G1 still reports total sales
    }

    @Test("refund: 1B > 1A yields a negative net (ATO owes you)")
    func refund() {
        let r = BasEngine.compute(
            txns: [txn(110_000), txn(-1_100_000)], gstRegistered: true,
            manual: BasEngine.Manual(paygInstalmentCents: 0))
        // 1A = round(110000/11)=10_000; 1B = round(1100000/11)=100_000 → net = -90_000.
        #expect(r.oneA == 10_000)
        #expect(r.oneB == 100_000)
        #expect(r.netGstCents == -90_000)
    }

    @Test("PAYG is summed into total but kept separate from net 9")
    func payg() {
        let r = BasEngine.compute(txns: [txn(1_100_000)], gstRegistered: true,
                                  manual: BasEngine.Manual(paygInstalmentCents: 25_000))
        #expect(r.netGstCents == 100_000)
        #expect(r.paygCents == 25_000)
        #expect(r.totalPayableCents == 125_000)
    }

    @Test("capital ≤ $1,000 falls into G11, not G10")
    func capitalThreshold() {
        // -100_000 cents = exactly $1,000 → NOT > $1,000 → G11.
        let r = BasEngine.compute(txns: [txn(-100_000, capital: true)], gstRegistered: true,
                                  manual: BasEngine.Manual(paygInstalmentCents: 0))
        #expect(r.g10 == 0)
        #expect(r.g11 == 100_000)
    }

    // The SHARED golden fixture (copied verbatim from the backend) — both engines
    // assert these identical numbers. The backend keys its vectors under "scenarios",
    // with manual params nested under "manual" and no per-txn txnDate (the engine math
    // is date-independent; the caller windows). Decode the real shape.
    private struct Golden: Decodable {
        struct Scenario: Decodable {
            let name: String
            let gstRegistered: Bool
            let manual: Manual
            let txns: [GTxn]
            let expected: Expected
        }
        struct Manual: Decodable { let paygInstalmentCents: Int }
        struct GTxn: Decodable { let amountCents: Int; let gstFree: Bool; let capital: Bool }
        struct Expected: Decodable {
            let g1, g3, g10, g11, g14, g17: Int
            let oneA, oneB: Int
            let netGstCents, paygCents, totalPayableCents: Int
        }
        let scenarios: [Scenario]
    }

    @Test("BasEngine matches every label of every golden vector")
    func goldenVectors() throws {
        // GoldenAnchor + the bundled resource are proven in FixtureBundlingTests.
        guard let url = Bundle(for: GoldenAnchor.self).url(forResource: "bas-golden", withExtension: "json") else {
            Issue.record("bas-golden.json missing from the test bundle — see FixtureBundlingTests/project.yml.")
            return
        }
        let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
        #expect(golden.scenarios.count >= 5)   // registered/non-registered/refund/empty/monthly
        for v in golden.scenarios {
            let r = BasEngine.compute(
                txns: v.txns.map { BasEngine.Txn(amountCents: $0.amountCents, gstFree: $0.gstFree,
                                                 capital: $0.capital, txnDate: "2026-04-15") },
                gstRegistered: v.gstRegistered,
                manual: BasEngine.Manual(paygInstalmentCents: v.manual.paygInstalmentCents))
            let e = v.expected
            #expect(r.g1 == e.g1, "\(v.name) g1")
            #expect(r.g3 == e.g3, "\(v.name) g3")
            #expect(r.oneA == e.oneA, "\(v.name) 1A")
            #expect(r.g10 == e.g10, "\(v.name) g10")
            #expect(r.g11 == e.g11, "\(v.name) g11")
            #expect(r.g14 == e.g14, "\(v.name) g14")
            #expect(r.g17 == e.g17, "\(v.name) g17")
            #expect(r.oneB == e.oneB, "\(v.name) 1B")
            #expect(r.netGstCents == e.netGstCents, "\(v.name) net9")
            #expect(r.paygCents == e.paygCents, "\(v.name) payg")
            #expect(r.totalPayableCents == e.totalPayableCents, "\(v.name) total")
        }
    }
}
