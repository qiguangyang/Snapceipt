import Foundation
import SwiftData
import Testing
@testable import Snapceipt

@MainActor
@Suite("Profile business fields + document rate")
struct ProfileBusinessFieldsTests {
    private func ctx() throws -> ModelContext {
        ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
    }

    @Test("Profile defaults: gstRateBp 1000, business fields nil")
    func profileDefaults() throws {
        let c = try ctx()
        let p = Profile(userId: "u1", name: "Biz", type: "business",
                        accent1: "#0E7C72", accent2: "#DCF0ED", accent3: "#0A5950")
        c.insert(p)
        try c.save()
        let stored = try c.fetch(FetchDescriptor<Profile>())[0]
        #expect(stored.gstRateBp == 1000)
        #expect(stored.businessEmail == nil)
        #expect(stored.phone == nil)
        #expect(stored.website == nil)
        #expect(stored.addressText == nil)
        #expect(stored.bankDetails == nil)
        #expect(stored.logoR2Key == nil)
    }

    @Test("Profile persists business fields + custom rate")
    func profilePersists() throws {
        let c = try ctx()
        let p = Profile(userId: "u1", name: "Biz", type: "business",
                        accent1: "#0E7C72", accent2: "#DCF0ED", accent3: "#0A5950",
                        gstRateBp: 1500, businessEmail: "hi@biz.au", phone: "0400 000 000",
                        website: "biz.au", addressText: "1 Test St\nSydney NSW",
                        bankDetails: "BSB 000-000\nAcct 12345678", logoR2Key: "u1/profiles/p1/logo")
        c.insert(p)
        try c.save()
        let s = try c.fetch(FetchDescriptor<Profile>())[0]
        #expect(s.gstRateBp == 1500)
        #expect(s.businessEmail == "hi@biz.au")
        #expect(s.phone == "0400 000 000")
        #expect(s.website == "biz.au")
        #expect(s.addressText == "1 Test St\nSydney NSW")
        #expect(s.bankDetails == "BSB 000-000\nAcct 12345678")
        #expect(s.logoR2Key == "u1/profiles/p1/logo")
    }

    @Test("Quote + Invoice gstRateBp default nil and persist a value")
    func documentRate() throws {
        let c = try ctx()
        let q = Quote(userId: "u1", profileId: "p1")
        let i = Invoice(userId: "u1", profileId: "p1")
        c.insert(q); c.insert(i)
        try c.save()
        let sq = try c.fetch(FetchDescriptor<Quote>())[0]
        let si = try c.fetch(FetchDescriptor<Invoice>())[0]
        #expect(sq.gstRateBp == nil)
        #expect(si.gstRateBp == nil)
        sq.gstRateBp = 1500
        si.gstRateBp = 1250
        try c.save()
        #expect(try c.fetch(FetchDescriptor<Quote>())[0].gstRateBp == 1500)
        #expect(try c.fetch(FetchDescriptor<Invoice>())[0].gstRateBp == 1250)
    }
}

@MainActor
@Suite("Profile/Quote/Invoice new-field sync round-trip")
struct NewFieldSyncTests {
    private func ctx() throws -> ModelContext {
        ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
    }

    @Test("Profile payload carries editable fields, OMITS logoR2Key")
    func profileEncode() throws {
        let p = Profile(userId: "u1", name: "Biz", type: "business",
                        accent1: "#0E7C72", accent2: "#DCF0ED", accent3: "#0A5950",
                        gstRateBp: 1500, businessEmail: "hi@biz.au", phone: "0400",
                        website: "biz.au", addressText: "1 St", bankDetails: "BSB 1",
                        logoR2Key: "u1/profiles/p1/logo")
        let registry = SyncEntityRegistry()
        let payload = registry.decodePayload(registry.encodePayload(entityType: .profile, entity: p))
        #expect(payload["gstRateBp"]?.intValue == 1500)
        #expect(payload["businessEmail"]?.stringValue == "hi@biz.au")
        #expect(payload["phone"]?.stringValue == "0400")
        #expect(payload["website"]?.stringValue == "biz.au")
        #expect(payload["address"]?.stringValue == "1 St")
        #expect(payload["bankDetails"]?.stringValue == "BSB 1")
        // logoR2Key is pull-only: NEVER in the outbound payload.
        #expect(payload["logoR2Key"] == nil)
    }

    @Test("Profile upsert decodes editable fields AND logoR2Key")
    func profileDecode() throws {
        let c = try ctx()
        let registry = SyncEntityRegistry()
        let envJSON = """
        {"type":"profile","id":"p1","userId":"u1",
         "name":"Biz","profileType":"business","accent1":"#0E7C72","accent2":"#DCF0ED",
         "accent3":"#0A5950","gstRateBp":1500,"businessEmail":"hi@biz.au","phone":"0400",
         "website":"biz.au","address":"1 St","bankDetails":"BSB 1",
         "logoR2Key":"u1/profiles/p1/logo",
         "createdAt":1,"updatedAt":2,"deletedAt":null,"rev":1,"lastEditedDeviceId":null}
        """
        let env = try JSONDecoder().decode(PullChange.self, from: Data(envJSON.utf8))
        registry.handler(for: .profile)?.applyPulled(c, env)
        try c.save()
        let s = try c.fetch(FetchDescriptor<Profile>())[0]
        #expect(s.gstRateBp == 1500)
        #expect(s.businessEmail == "hi@biz.au")
        #expect(s.phone == "0400")
        #expect(s.website == "biz.au")
        #expect(s.addressText == "1 St")
        #expect(s.bankDetails == "BSB 1")
        #expect(s.logoR2Key == "u1/profiles/p1/logo")
    }

    @Test("Quote + Invoice round-trip gstRateBp")
    func documentRateRoundTrip() throws {
        let registry = SyncEntityRegistry()
        let q = Quote(userId: "u1", profileId: "p1", gstRateBp: 1500)
        let i = Invoice(userId: "u1", profileId: "p1", gstRateBp: 1250)
        let qf = registry.decodePayload(registry.encodePayload(entityType: .quote, entity: q))
        let invf = registry.decodePayload(registry.encodePayload(entityType: .invoice, entity: i))
        #expect(qf["gstRateBp"]?.intValue == 1500)
        #expect(invf["gstRateBp"]?.intValue == 1250)
    }
}
