import Foundation
import Observation
import SwiftData
import UserNotifications

@MainActor
protocol FollowUpNotificationCenter {
    func isAuthorized() async throws -> Bool
    func requestAuthorization() async throws -> Bool
    func pendingIdentifiers() async throws -> Set<String>
    func deliveredIdentifiers() async throws -> Set<String>
    func add(_ request: FollowUpNotificationPlan.Request) async throws
    func removePending(_ ids: Set<String>) async throws
    func removeDelivered(_ ids: Set<String>) async throws
}

@MainActor
struct DeviceFollowUpNotificationCenter: FollowUpNotificationCenter {
    private let center = UNUserNotificationCenter.current()
    func isAuthorized() async throws -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional || status == .ephemeral
    }
    func requestAuthorization() async throws -> Bool { try await center.requestAuthorization(options: [.alert, .sound]) }
    func pendingIdentifiers() async throws -> Set<String> { Set(await center.pendingNotificationRequests().map(\.identifier)) }
    func deliveredIdentifiers() async throws -> Set<String> { Set(await center.deliveredNotifications().map { $0.request.identifier }) }
    func add(_ request: FollowUpNotificationPlan.Request) async throws {
        let content = UNMutableNotificationContent()
        content.title = "Client follow-up due"
        content.body = "Open Snapceipt to review your follow-up."
        content.userInfo = request.payload.userInfo
        content.sound = .default
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: Double(request.dueAt) / 1000))
        components.timeZone = utc.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try await center.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: trigger))
    }
    func removePending(_ ids: Set<String>) async throws { center.removePendingNotificationRequests(withIdentifiers: Array(ids)) }
    func removeDelivered(_ ids: Set<String>) async throws { center.removeDeliveredNotifications(withIdentifiers: Array(ids)) }
}

/// One main-actor worker owns all notification changes. Repeated reconciliations coalesce
/// to the latest immutable plan; synchronous auth invalidation prevents stale adds.
@MainActor @Observable
final class FollowUpNotificationScheduler {
    enum RecordStatus: String { case scheduled = "Scheduled on this device", inAppOnly = "In-app only" }
    struct Result {
        var scheduledIds: Set<String> = []
        var failures: [String: String] = [:]
    }
    private struct Work {
        let userId: String
        let epoch: Int
        let enabled: Bool
        let requests: [FollowUpNotificationPlan.Request]
    }
    @ObservationIgnored private let center: any FollowUpNotificationCenter
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let context: ModelContext?
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var activeUserId: String?
    @ObservationIgnored private var latest: Work?
    @ObservationIgnored private var cancellations: Set<String> = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    private(set) var result = Result()
    private(set) var deviceNotificationsEnabled = false

    init(center: (any FollowUpNotificationCenter)? = nil,
         defaults: UserDefaults = .standard, context: ModelContext? = nil) {
        self.center = center ?? DeviceFollowUpNotificationCenter(); self.defaults = defaults; self.context = context
    }
    static func preferenceKey(userId: String) -> String { "sc.notif.clientFollowUps.\(userId)" }
    func isEnabled(userId: String) -> Bool {
        activeUserId == userId ? deviceNotificationsEnabled : defaults.bool(forKey: Self.preferenceKey(userId: userId))
    }

    /// Call synchronously from auth restoration/change, before launching reconciliation.
    func setUser(_ userId: String?) {
        let userId = userId.flatMap { $0.isEmpty ? nil : $0 }
        guard userId != activeUserId else { return }
        if let old = activeUserId { cancellations.insert(old) }
        epoch += 1; activeUserId = userId; latest = nil; result = Result()
        deviceNotificationsEnabled = userId.map { defaults.bool(forKey: Self.preferenceKey(userId: $0)) } ?? false
        startWorker()
    }
    /// Wipe callbacks remain synchronous: invalidate first, then clean asynchronously.
    func invalidateAuthentication() { setUser(nil) }

    func setEnabled(_ enabled: Bool, userId: String) async {
        guard activeUserId == userId else { return }
        let operationEpoch = epoch
        defaults.set(enabled, forKey: Self.preferenceKey(userId: userId))
        deviceNotificationsEnabled = enabled
        if enabled { _ = try? await center.requestAuthorization() }
        guard epoch == operationEpoch && activeUserId == userId else { return }
        await refresh()
    }
    func status(for followUp: ClientFollowUp) -> RecordStatus {
        guard followUp.userId == activeUserId,
              result.scheduledIds.contains(FollowUpNotificationPlan.prefix(userId: followUp.userId) + followUp.id) else { return .inAppOnly }
        return .scheduled
    }

    /// Fetch each verified live business profile with explicit user + profile predicates.
    func refresh() async {
        guard let context, let userId = activeUserId else { return }
        let operationEpoch = epoch
        do {
            let profiles = try context.fetch(FetchDescriptor<Profile>(predicate: #Predicate {
                $0.userId == userId && $0.deletedAt == nil && $0.type == "business"
            }))
            var followUps: [ClientFollowUp] = []
            var liveClients: Set<String> = []
            for profile in profiles {
                let profileId = profile.id
                let clients = try context.fetch(FetchDescriptor<Client>(predicate: #Predicate {
                    $0.userId == userId && $0.profileId == profileId && $0.deletedAt == nil
                }))
                let clientIds = Set(clients.map(\.id))
                liveClients.formUnion(clientIds)
                let rows = try context.fetch(FetchDescriptor<ClientFollowUp>(predicate: #Predicate {
                    $0.userId == userId && $0.profileId == profileId && $0.deletedAt == nil
                }))
                followUps += rows.filter { clientIds.contains($0.clientId) }
            }
            guard epoch == operationEpoch else { return }
            _ = await reconcile(followUps: followUps, liveClientIds: liveClients, liveBusinessProfileIds: Set(profiles.map(\.id)),
                                userId: userId, now: Epoch.nowMs(), enabled: isEnabled(userId: userId))
        } catch {
            if epoch == operationEpoch { result = Result(failures: ["store": error.localizedDescription]) }
        }
    }

    func reconcile(followUps: [ClientFollowUp], liveClientIds: Set<String>, liveBusinessProfileIds: Set<String>,
                   userId: String, now: Int, enabled: Bool) async -> Result {
        guard activeUserId == userId else { return Result() }
        // Snapshot before the first await; mutations during suspension cannot alter this plan.
        latest = Work(userId: userId, epoch: epoch, enabled: enabled,
                      requests: FollowUpNotificationPlan.requests(followUps: followUps, liveClientIds: liveClientIds,
                          liveBusinessProfileIds: liveBusinessProfileIds, userId: userId, now: now, enabled: enabled, authorized: true))
        startWorker()
        await worker?.value
        return activeUserId == userId ? result : Result()
    }
    func cancelAll(userId: String) async {
        if activeUserId == userId { invalidateAuthentication() }
        cancellations.insert(userId); startWorker(); await worker?.value
    }
    private func startWorker() {
        guard worker == nil, latest != nil || !cancellations.isEmpty else { return }
        worker = Task { await drain() }
    }
    private func drain() async {
        while !cancellations.isEmpty || latest != nil {
            if let userId = cancellations.sorted().first {
                cancellations.remove(userId)
                await removeAll(userId: userId)
                continue
            }
            guard let work = latest else { continue }
            latest = nil
            await apply(work)
        }
        worker = nil
    }
    private func isCurrent(_ work: Work) -> Bool { epoch == work.epoch && activeUserId == work.userId }
    private func apply(_ work: Work) async {
        var next = Result()
        do {
            let authorized = try await center.isAuthorized()
            guard isCurrent(work) else { return }
            let desired = work.enabled && authorized ? work.requests : []
            let desiredIds = Set(desired.map(\.identifier))
            let prefix = FollowUpNotificationPlan.prefix(userId: work.userId)
            let pending = try await center.pendingIdentifiers()
            guard isCurrent(work) else { return }
            let delivered = try await center.deliveredIdentifiers()
            guard isCurrent(work) else { return }
            try await center.removePending(Set(pending.filter { $0.hasPrefix(prefix) }).subtracting(desiredIds))
            guard isCurrent(work) else { return }
            try await center.removeDelivered(Set(delivered.filter { $0.hasPrefix(prefix) }).subtracting(desiredIds))
            guard isCurrent(work) else { return }
            for request in desired {
                guard isCurrent(work) else { return }
                do {
                    try await center.add(request)
                    guard isCurrent(work) else { return } // queued cancellation cleans a suspended stale add
                    next.scheduledIds.insert(request.identifier)
                } catch {
                    next.failures[request.identifier] = error.localizedDescription
                    // A failed replacement must not leave the old due instant scheduled.
                    if isCurrent(work) {
                        try? await center.removePending([request.identifier])
                        try? await center.removeDelivered([request.identifier])
                    }
                }
            }
        } catch { next.failures["center"] = error.localizedDescription }
        if isCurrent(work) { result = next }
    }
    private func removeAll(userId: String) async {
        let prefix = FollowUpNotificationPlan.prefix(userId: userId)
        // Independent attempts preserve delivered cleanup even if pending cleanup fails.
        do { let ids = try await center.pendingIdentifiers(); try await center.removePending(Set(ids.filter { $0.hasPrefix(prefix) })) }
        catch { result.failures["pendingCleanup"] = error.localizedDescription }
        do { let ids = try await center.deliveredIdentifiers(); try await center.removeDelivered(Set(ids.filter { $0.hasPrefix(prefix) })) }
        catch { result.failures["deliveredCleanup"] = error.localizedDescription }
    }
}
