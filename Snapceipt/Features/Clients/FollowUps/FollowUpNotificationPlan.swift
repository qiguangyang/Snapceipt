import Foundation

enum FollowUpNotificationPlan {
    struct Payload: Equatable {
        let type = "client_follow_up"
        let userId: String
        let profileId: String
        let clientId: String
        let followUpId: String
        var userInfo: [String: String] {
            ["type": type, "userId": userId, "profileId": profileId, "clientId": clientId, "followUpId": followUpId]
        }
    }
    struct Request: Equatable {
        let identifier: String
        let dueAt: Int
        let payload: Payload
    }
    static func prefix(userId: String) -> String { "sc.clientFollowUp.\(userId)." }
    static func requests(followUps: [ClientFollowUp], liveClientIds: Set<String>, liveBusinessProfileIds: Set<String>,
                         userId: String, now: Int, enabled: Bool, authorized: Bool) -> [Request] {
        guard enabled && authorized && !userId.isEmpty else { return [] }
        return followUps.filter { row in
            row.userId == userId && row.deletedAt == nil && row.completedAt == nil && row.dueAt > now
                && liveClientIds.contains(row.clientId) && row.profileId.map(liveBusinessProfileIds.contains) == true
        }.sorted { $0.dueAt == $1.dueAt ? $0.id < $1.id : $0.dueAt < $1.dueAt }.prefix(32).map {
            Request(identifier: prefix(userId: userId) + $0.id, dueAt: $0.dueAt,
                    payload: Payload(userId: userId, profileId: $0.profileId!, clientId: $0.clientId, followUpId: $0.id))
        }
    }
}
