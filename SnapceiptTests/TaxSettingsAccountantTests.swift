import Testing
import Foundation
@testable import Snapceipt

@Suite("TaxSettings.accountantEmail")
struct TaxSettingsAccountantTests {
    @Test("init defaults accountantEmail to nil and stores a set value")
    func initStores() {
        let a = TaxSettings(userId: "u1", profileId: "p1")
        #expect(a.accountantEmail == nil)
        let b = TaxSettings(userId: "u1", profileId: "p1", accountantEmail: "cpa@firm.au")
        #expect(b.accountantEmail == "cpa@firm.au")
    }

    @Test("payload includes accountantEmail; null when nil")
    func payloadField() {
        let row = TaxSettings(userId: "u1", profileId: "p1", accountantEmail: "cpa@firm.au")
        let json = SyncEntityRegistry.shared.encodePayload(entityType: .taxSettings, entity: row)
        #expect(json.contains("\"accountantEmail\":\"cpa@firm.au\""))

        let empty = TaxSettings(userId: "u1", profileId: "p1")
        let json2 = SyncEntityRegistry.shared.encodePayload(entityType: .taxSettings, entity: empty)
        #expect(json2.contains("\"accountantEmail\":null"))
    }
}
