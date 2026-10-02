import Testing
import Foundation
import SwiftData
@testable import Snapceipt

@MainActor
final class FakeFollowUpCenter: FollowUpNotificationCenter {
    var authorized = true
    var pending: [String: FollowUpNotificationPlan.Request] = [:]
    var delivered: Set<String> = []
    var failAdd = false
    var authorizationRequests = 0
    var addGate: CheckedContinuation<Void, Never>?
    var suspendAdd = false
    func isAuthorized() async throws -> Bool { authorized }
    func requestAuthorization() async throws -> Bool { authorizationRequests += 1; return authorized }
    func pendingIdentifiers() async throws -> Set<String> { Set(pending.keys) }
    func deliveredIdentifiers() async throws -> Set<String> { delivered }
    func add(_ request: FollowUpNotificationPlan.Request) async throws {
        if suspendAdd { await withCheckedContinuation { addGate = $0 } }
        if failAdd { throw NSError(domain: "test", code: 1) }
        pending[request.identifier] = request
    }
    func removePending(_ ids: Set<String>) async throws { for id in ids { pending[id] = nil } }
    func removeDelivered(_ ids: Set<String>) async throws { delivered.subtract(ids) }
}

@MainActor @Suite("FollowUpNotification")
struct FollowUpNotificationTests {
    private func follow(_ id: String, due: Int = 200, user: String = "u1", profile: String = "p1", client: String = "c1") -> ClientFollowUp {
        ClientFollowUp(id: id, userId: user, profileId: profile, clientId: client, title: "Private name and notes", dueAt: due)
    }
    @Test func plannerFiltersAndCapsEarliest32() {
        var records = (0..<40).map { follow(String(format: "%02d", $0), due: 200 + $0) }
        let done = follow("done"); done.completedAt = 1
        let deleted = follow("deleted"); deleted.deletedAt = 1
        records += [done, deleted, follow("past", due: 99), follow("foreign", user: "u2"), follow("missing", client: "missing"), follow("personal", profile: "personal")]
        let plan = FollowUpNotificationPlan.requests(followUps: records.reversed(), liveClientIds: ["c1"], liveBusinessProfileIds: ["p1"], userId: "u1", now: 100, enabled: true, authorized: true)
        #expect(plan.count == 32 && plan.first?.identifier == "sc.clientFollowUp.u1.00" && plan.last?.identifier == "sc.clientFollowUp.u1.31")
        #expect(plan.first?.payload.type == "client_follow_up" && plan.first?.payload.profileId == "p1")
        #expect(FollowUpNotificationPlan.requests(followUps: records, liveClientIds: ["c1"], liveBusinessProfileIds: ["p1"], userId: "u1", now: 100, enabled: false, authorized: true).isEmpty)
    }
    @Test func reconciliationReplacesAndCleansDeliveredOnlyStaleRecords() async {
        let center = FakeFollowUpCenter()
        let s = FollowUpNotificationScheduler(center: center); s.setUser("u1")
        let f = follow("f")
        center.delivered = ["sc.clientFollowUp.u1.removed-row", "unrelated"]
        var r = await s.reconcile(followUps: [f], liveClientIds: ["c1"], liveBusinessProfileIds: ["p1"], userId: "u1", now: 100, enabled: true)
        #expect(r.scheduledIds == ["sc.clientFollowUp.u1.f"] && center.delivered == ["unrelated"])
        f.dueAt = 300
        r = await s.reconcile(followUps: [f], liveClientIds: ["c1"], liveBusinessProfileIds: ["p1"], userId: "u1", now: 100, enabled: true)
        #expect(center.pending.count == 1 && center.pending["sc.clientFollowUp.u1.f"]?.dueAt == 300)
        center.delivered.insert("sc.clientFollowUp.u1.f"); f.completedAt = 200
        r = await s.reconcile(followUps: [f], liveClientIds: ["c1"], liveBusinessProfileIds: ["p1"], userId: "u1", now: 100, enabled: true)
        #expect(r.scheduledIds.isEmpty && center.pending.isEmpty && center.delivered == ["unrelated"])
    }
    @Test func deniedDisabledAndAddFailureKeepRecordsInApp() async {
        let c = FakeFollowUpCenter(), f = follow("f")
        let s = FollowUpNotificationScheduler(center: c); s.setUser("u1")
        c.authorized = false
        let denied = await s.reconcile(followUps: [f], liveClientIds: ["c1"], liveBusinessProfileIds: ["p1"], userId: "u1", now: 100, enabled: true)
        #expect(denied.scheduledIds.isEmpty && f.completedAt == nil && f.deletedAt == nil && c.authorizationRequests == 0)
        c.authorized = true
        _ = await s.reconcile(followUps: [f], liveClientIds: ["c1"], liveBusinessProfileIds: ["p1"], userId: "u1", now: 100, enabled: true)
        f.dueAt = 500; c.failAdd = true
        let failed = await s.reconcile(followUps: [f], liveClientIds: ["c1"], liveBusinessProfileIds: ["p1"], userId: "u1", now: 100, enabled: true)
        #expect(failed.failures["sc.clientFollowUp.u1.f"] != nil && s.status(for: f) == .inAppOnly)
        #expect(c.pending.isEmpty)
        c.failAdd = false
        let disabled = await s.reconcile(followUps: [f], liveClientIds: ["c1"], liveBusinessProfileIds: ["p1"], userId: "u1", now: 100, enabled: false)
        #expect(disabled.scheduledIds.isEmpty)
    }
    @Test func invalidationDuringAddCannotReAddOldUserReminder() async {
        let c = FakeFollowUpCenter(); c.suspendAdd = true
        let s = FollowUpNotificationScheduler(center: c); s.setUser("u1")
        let task = Task { await s.reconcile(followUps: [follow("f")], liveClientIds: ["c1"], liveBusinessProfileIds: ["p1"], userId: "u1", now: 100, enabled: true) }
        while c.addGate == nil { await Task.yield() }
        s.invalidateAuthentication()
        c.suspendAdd = false; c.addGate?.resume(); c.addGate = nil
        _ = await task.value
        await s.cancelAll(userId: "u1")
        #expect(c.pending.isEmpty && c.delivered.isEmpty)
        let stale = await s.reconcile(followUps: [follow("f")], liveClientIds: ["c1"], liveBusinessProfileIds: ["p1"], userId: "u1", now: 100, enabled: true)
        #expect(stale.scheduledIds.isEmpty && c.pending.isEmpty)
    }
}

@MainActor @Suite("FollowUpNotificationIntegration")
struct FollowUpNotificationIntegrationTests {
    @Test func optInIsPerUserAndDoesNotUpdateBackendPushSettings() async throws {
        let name = "task8.\(UUID().uuidString)", center = FakeFollowUpCenter()
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let scheduler = FollowUpNotificationScheduler(center: center, defaults: defaults)
        scheduler.setUser("u1")
        let api = MockAPIClient()
        let vm = NotificationsSettingsViewModel(api: api, defaults: defaults, userId: "u1", followUpScheduler: scheduler)
        #expect(!vm.clientFollowUpsEnabled)
        await vm.setClientFollowUpsEnabled(true)
        #expect(defaults.bool(forKey: "sc.notif.clientFollowUps.u1"))
        #expect(!defaults.bool(forKey: "sc.notif.clientFollowUps.u2"))
        #expect(center.authorizationRequests == 1 && api.updateDeviceCalls.isEmpty)
        await vm.setClientFollowUpsEnabled(false)
        #expect(center.authorizationRequests == 1 && !scheduler.isEnabled(userId: "u1"))
    }
    @Test func scopedRefreshIncludesAllBusinessProfilesAndExcludesMismatchedClient() async throws {
        let context = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        let center = FakeFollowUpCenter(), name = "task8.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "sc.notif.clientFollowUps.u1")
        for (id, user, type) in [("p1", "u1", "business"), ("p2", "u1", "business"), ("p3", "u1", "personal"), ("p4", "u2", "business")] {
            context.insert(Profile(id: id, userId: user, name: id, type: type, accent1: "#000000", accent2: "#000000", accent3: "#000000"))
            context.insert(Client(id: "c" + id, userId: user, profileId: id, name: "Private"))
            context.insert(ClientFollowUp(id: "f" + id, userId: user, profileId: id, clientId: "c" + id, title: "Private", dueAt: Epoch.nowMs() + 3_600_000))
        }
        context.insert(ClientFollowUp(id: "wrong", userId: "u1", profileId: "p1", clientId: "cp2", title: "Mismatch", dueAt: Epoch.nowMs() + 3_600_000))
        try context.save()
        let s = FollowUpNotificationScheduler(center: center, defaults: defaults, context: context); s.setUser("u1")
        await s.refresh()
        #expect(Set(center.pending.keys) == ["sc.clientFollowUp.u1.fp1", "sc.clientFollowUp.u1.fp2"])
        center.delivered = ["sc.clientFollowUp.u1.fp1", "sc.clientFollowUp.u2.keep", "backend-push"]
        await s.cancelAll(userId: "u1")
        #expect(center.pending.isEmpty && center.delivered == ["sc.clientFollowUp.u2.keep", "backend-push"])
    }
    @Test func newCoalescedPlanWinsAndCapEntriesRemainInApp() async {
        let c = FakeFollowUpCenter(); c.suspendAdd = true
        let s = FollowUpNotificationScheduler(center: c); s.setUser("u1")
        let records = (0..<33).map { ClientFollowUp(id: "f\($0)", userId: "u1", profileId: "p1", clientId: "c", dueAt: 200 + $0) }
        let first = Task { await s.reconcile(followUps: records, liveClientIds: ["c"], liveBusinessProfileIds: ["p1"], userId: "u1", now: 100, enabled: true) }
        while c.addGate == nil { await Task.yield() }
        let last = Task { await s.reconcile(followUps: [], liveClientIds: [], liveBusinessProfileIds: ["p1"], userId: "u1", now: 100, enabled: true) }
        await Task.yield()
        c.suspendAdd = false; c.addGate?.resume(); c.addGate = nil
        _ = await first.value; _ = await last.value
        #expect(c.pending.isEmpty && s.status(for: records[32]) == .inAppOnly)
    }
}

private final class FollowUpSignalCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func record() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor @Suite("FollowUpSyncSignals", .serialized)
struct FollowUpSyncSignalTests {
    @Test func successfulPullAndPushEmitGenericSignal() async throws {
        let context = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        let api = MockAPIClient()
        let engine = SyncEngine(api: api, context: context, auth: AuthStore(), toast: ToastCenter())
        let counter = FollowUpSignalCounter()
        let observer = NotificationCenter.default.addObserver(forName: .syncDidApplyChanges, object: engine, queue: nil) { _ in counter.record() }
        defer { NotificationCenter.default.removeObserver(observer) }
        api.pullHandler = { _, _ in PullResponse(changes: [], nextCursor: nil, hasMore: false, serverTime: 1) }
        await engine.pull()
        #expect(counter.value == 1)
        let row = ClientFollowUp(userId: "u1", profileId: "p1", clientId: "c", dueAt: 200)
        context.insert(row); engine.enqueue(op: "upsert", entityType: .clientFollowUp, entity: row)
        api.pushHandler = { mutations in
            PushResponse(results: mutations.map { PushResult(mutationId: $0.mutationId, status: "applied", reason: nil, entity: nil) }, serverTime: 1)
        }
        await engine.push()
        #expect(counter.value == 2)
    }
    @Test func clientDeletionEmitsLocalReconciliationSignal() throws {
        let context = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        let client = Client(userId: "u1", profileId: "p1", name: "Client")
        context.insert(client); try context.save()
        let store = ClientStore(context: context, sync: MockSyncEngine(), userId: "u1", profileId: "p1")
        let counter = FollowUpSignalCounter()
        let observer = NotificationCenter.default.addObserver(forName: .clientFollowUpsDidChange, object: nil, queue: nil) { _ in counter.record() }
        defer { NotificationCenter.default.removeObserver(observer) }
        try store.delete(id: client.id)
        #expect(counter.value == 1)
    }
}

@MainActor @Suite("FollowUpNotificationStatuses")
struct FollowUpNotificationStatusTests {
    @Test func earliest32ScheduledAndReopenedPastDueStaysInApp() async {
        let center = FakeFollowUpCenter()
        let s = FollowUpNotificationScheduler(center: center); s.setUser("u1")
        let records = (0..<33).map { ClientFollowUp(id: "f\($0)", userId: "u1", profileId: "p1", clientId: "c", dueAt: 200 + $0) }
        _ = await s.reconcile(followUps: records, liveClientIds: ["c"], liveBusinessProfileIds: ["p1"], userId: "u1", now: 100, enabled: true)
        #expect(center.pending.count == 32 && s.status(for: records[0]) == .scheduled && s.status(for: records[32]) == .inAppOnly)
        records[0].completedAt = 250
        _ = await s.reconcile(followUps: records, liveClientIds: ["c"], liveBusinessProfileIds: ["p1"], userId: "u1", now: 300, enabled: true)
        records[0].completedAt = nil
        _ = await s.reconcile(followUps: records, liveClientIds: ["c"], liveBusinessProfileIds: ["p1"], userId: "u1", now: 300, enabled: true)
        #expect(center.pending.isEmpty && s.status(for: records[0]) == .inAppOnly && records[0].dueAt == 200)
    }
    @Test func accountSwitchRemovesOnlyPreviousUserPendingAndDelivered() async {
        let center = FakeFollowUpCenter()
        let scheduler = FollowUpNotificationScheduler(center: center); scheduler.setUser("u1")
        let f = ClientFollowUp(id: "f", userId: "u1", profileId: "p1", clientId: "c", dueAt: 200)
        _ = await scheduler.reconcile(followUps: [f], liveClientIds: ["c"], liveBusinessProfileIds: ["p1"], userId: "u1", now: 100, enabled: true)
        center.delivered = ["sc.clientFollowUp.u1.f", "email-in", "sc.clientFollowUp.u2.keep"]
        scheduler.setUser("u2")
        await scheduler.cancelAll(userId: "u1")
        #expect(center.pending.isEmpty && center.delivered == ["email-in", "sc.clientFollowUp.u2.keep"])
        #expect(scheduler.status(for: f) == .inAppOnly)
    }
}
