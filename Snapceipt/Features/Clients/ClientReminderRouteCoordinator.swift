import Foundation
import Observation
import SwiftData

/// Only routing identifiers may be retained before the authenticated workspace is ready.
struct ClientReminderRoute: Equatable {
    let userId: String
    let profileId: String
    let clientId: String
    let followUpId: String

    init(userId: String, profileId: String, clientId: String, followUpId: String) {
        self.userId = userId; self.profileId = profileId; self.clientId = clientId; self.followUpId = followUpId
    }
    init?(userInfo: [AnyHashable: Any]) {
        guard userInfo["type"] as? String == "client_follow_up" else { return nil }
        func id(_ key: String) -> String? {
            guard let value = userInfo[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
        guard let user = id("userId"), let profile = id("profileId"), let client = id("clientId"), let followUp = id("followUpId") else { return nil }
        self.init(userId: user, profileId: profile, clientId: client, followUpId: followUp)
    }
}

@Observable @MainActor
final class ClientReminderRouteCoordinator {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let profiles: ProfilesStore
    @ObservationIgnored private let router: Router
    @ObservationIgnored private let currentUser: () -> String?
    @ObservationIgnored private let restore: () async -> Void
    private(set) var pendingRoute: ClientReminderRoute?
    private var knownUser: String?
    private var epoch = 0
    private var ready = false
    private var resolving = false

    init(context: ModelContext, profiles: ProfilesStore, router: Router,
         currentUser: @escaping () -> String?, restore: @escaping () async -> Void = {}) {
        self.context = context; self.profiles = profiles; self.router = router
        self.currentUser = currentUser; self.restore = restore; knownUser = currentUser()
    }
    func receive(_ route: ClientReminderRoute) {
        guard currentUser() == nil || currentUser() == route.userId else { return }
        pendingRoute = route
        if ready { Task { await resumeAfterSessionRestoration() } }
    }
    func sessionChanged(to userId: String?) {
        guard userId != knownUser else { return }
        epoch += 1; ready = false
        if knownUser != nil || (pendingRoute != nil && pendingRoute?.userId != userId) { pendingRoute = nil }
        knownUser = userId
    }
    func invalidateAuthentication() {
        epoch += 1; ready = false; pendingRoute = nil; knownUser = nil
    }
    func resumeAfterSessionRestoration() async {
        guard !resolving, let userId = currentUser(), !userId.isEmpty else { return }
        let generation = epoch
        resolving = true
        await restore()
        resolving = false
        guard epoch == generation, currentUser() == userId else { return }
        ready = true
        guard let route = pendingRoute else { return }
        pendingRoute = nil
        guard route.userId == userId else { return }
        let pid = route.profileId, cid = route.clientId, fid = route.followUpId
        do {
            // Profile ownership and business eligibility precede every domain query.
            let profileRows = try context.fetch(FetchDescriptor<Profile>(predicate: #Predicate {
                $0.id == pid && $0.userId == userId && $0.deletedAt == nil && $0.type == "business"
            }))
            guard profileRows.contains(where: { $0.id == pid && $0.userId == userId && $0.deletedAt == nil && $0.type == "business" }) else { return }
            let clients = try context.fetch(FetchDescriptor<Client>(predicate: #Predicate {
                $0.id == cid && $0.userId == userId && $0.profileId == pid && $0.deletedAt == nil
            }))
            guard clients.contains(where: { $0.id == cid && $0.userId == userId && $0.profileId == pid && $0.deletedAt == nil }) else { return }
            let reminders = try context.fetch(FetchDescriptor<ClientFollowUp>(predicate: #Predicate {
                $0.id == fid && $0.userId == userId && $0.profileId == pid && $0.clientId == cid && $0.deletedAt == nil && $0.completedAt == nil
            }))
            guard reminders.contains(where: { $0.id == fid && $0.userId == userId && $0.profileId == pid && $0.clientId == cid && $0.deletedAt == nil && $0.completedAt == nil }),
                  epoch == generation, currentUser() == userId else { return }
            profiles.rescope(to: userId)
            profiles.setActive(pid)
            guard profiles.activeProfileId == pid else { return }
            router.openClient(cid)
        } catch { /* Stale/unavailable local data must never open contact information. */ }
    }
}
