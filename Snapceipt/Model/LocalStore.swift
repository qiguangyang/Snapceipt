import Foundation
import SwiftData

/// Local-data lifecycle helper for sign-out / account-deletion.
///
/// Wipes every SwiftData model + the on-disk receipt images, and resets the
/// sync/active-profile state, so a later sign-in — possibly a DIFFERENT account on the
/// same device — starts from a clean, fully re-synced slate rather than inheriting the
/// prior account's financial rows or pull cursor. Leaving the store intact on sign-out /
/// delete would leave financial data readable on the device, contradicting the
/// "delete my data" action and the privacy policy.
enum LocalStore {
    /// UserDefaults keys that scope sync + active-profile state to the signed-in user.
    /// Cleared on wipe so a new session can't inherit the prior account's pull cursor
    /// (which would silently skip server changes) or active-profile selection.
    private static let scopedDefaultsKeys = ["sc.syncCursor", "sc.activeProfile"]

    /// Delete all local domain rows, the outbox, pending receipts, and cached receipt
    /// JPEGs, then reset scoped UserDefaults. Best-effort: per-model failures are
    /// swallowed (a partial wipe still beats leaving financial data on disk).
    @MainActor
    static func wipe(context: ModelContext) {
        for type in SnapceiptSchema.models {
            try? context.delete(model: type)
        }
        try? context.save()
        clearReceiptImages()
        for key in scopedDefaultsKeys { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// Remove the cached receipt JPEGs under `<Application Support>/receipts` so the most
    /// sensitive artifact doesn't survive a sign-out / account deletion on the device.
    private static func clearReceiptImages() {
        guard let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("receipts", isDirectory: true) else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}
