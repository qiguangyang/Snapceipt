import Foundation
import Observation

/// The app-wide entitlement the UI reads. `plan` is the UNION of two truths:
///   - local StoreKit entitlement (this device just purchased / has an active txn)
///   - the backend plan from GET /auth/me (cross-device, the server flipped it)
/// Either being "pro" yields Pro access; this fails CLOSED to "free". `@Observable`
/// so gated views re-render the instant entitlement changes. Injected via the
/// environment in SnapceiptApp.
@MainActor
@Observable
final class EntitlementStore {
    private(set) var localEntitled = false
    private(set) var serverPlan = "free"

    /// The effective plan string ("pro" | "free"), consumed by ProGate(plan:).
    var plan: String { (localEntitled || serverPlan == "pro") ? "pro" : "free" }
    var isPro: Bool { plan == "pro" }

    /// Convenience gate built from the effective plan.
    var gate: ProGate { ProGate(plan: plan) }

    /// Set by StoreKitService.onEntitlementChange.
    func setLocalEntitled(_ entitled: Bool) { localEntitled = entitled }

    /// Set after a GET /auth/me round-trip (server is authoritative cross-device).
    func applyServerPlan(_ plan: String) { serverPlan = plan }
}
