import Foundation

/// Local-only (NOT synced in v1) per-profile/period BAS state (spec §4.6): the
/// editable PAYG instalment + a Mark-as-lodged snapshot. Keyed
/// `sc.bas.<profileId>.<periodKey>`. Drift is advisory (the snapshot never locks
/// data; corrections go on the next BAS).
final class BasLocalStore {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The filed-quarter snapshot stored at Mark-as-lodged.
    struct Snapshot: Codable, Equatable {
        let g1, oneA, oneB, netGst, payg, total: Int
        let lodgedAtMs: Int
    }

    private func base(_ profileId: String, _ periodKey: String) -> String {
        "sc.bas.\(profileId).\(periodKey)"
    }

    func paygInstalmentCents(profileId: String, periodKey: String) -> Int {
        defaults.integer(forKey: base(profileId, periodKey) + ".payg")
    }

    func setPaygInstalmentCents(_ cents: Int, profileId: String, periodKey: String) {
        defaults.set(max(0, cents), forKey: base(profileId, periodKey) + ".payg")
    }

    func markLodged(_ snapshot: Snapshot, profileId: String, periodKey: String) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: base(profileId, periodKey) + ".lodged")
    }

    func lodgedSnapshot(profileId: String, periodKey: String) -> Snapshot? {
        guard let data = defaults.data(forKey: base(profileId, periodKey) + ".lodged") else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// True iff a snapshot exists and any reportable figure differs from `current`
    /// (lodgedAtMs is excluded from the comparison — it is a timestamp, not a figure).
    func hasDrifted(current: Snapshot, profileId: String, periodKey: String) -> Bool {
        guard let snap = lodgedSnapshot(profileId: profileId, periodKey: periodKey) else { return false }
        return snap.g1 != current.g1 || snap.oneA != current.oneA || snap.oneB != current.oneB
            || snap.netGst != current.netGst || snap.payg != current.payg || snap.total != current.total
    }
}
