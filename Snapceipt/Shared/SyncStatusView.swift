import SwiftUI

/// A11y-only sync-state probe. The sync state is shown VISUALLY by the avatar ring on the Home
/// header (`ProfileSwitcherHeader`): green while syncing, red when the server is unreachable, none
/// when idle. The old floating "Syncing…" pill was removed per product. This zero-footprint element
/// persists the raw state token (idle/syncing/offline/error) as an a11y value so XCUITest can read
/// it across a sync drain; it lives in the shell so the token is readable on every tab.
struct SyncStatusView: View {
    let status: SyncStatus

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(AccessibilityID.syncStatusPill)
            .accessibilityValue(stateToken)
    }

    /// Raw state token surfaced as the a11y value, independent of any visible UI, so test
    /// predicates match on stable strings.
    private var stateToken: String {
        switch status {
        case .idle:    return "idle"
        case .syncing: return "syncing"
        case .offline: return "offline"
        case .error:   return "error"
        }
    }
}
