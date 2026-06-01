import Foundation
import LocalAuthentication

/// Drives the biometric app-lock gate (spec §6): on cold launch and on
/// background→active, if the lock is enabled present a blocking lock screen and
/// require a `LAContext.deviceOwnerAuthentication` pass (biometry with
/// device-passcode fallback) before revealing the app. The biometric evaluator
/// is injected (defaulting to `LAContext`) so the controller is unit-testable
/// without real hardware. The enabled flag persists in `UserDefaults`
/// (`sc.lock.enabled`). Enabling the lock requires a successful check first so a
/// user can't lock themselves out on a device with no biometry/passcode.
@Observable
@MainActor
final class AppLockController {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let canEvaluate: () -> Bool
    @ObservationIgnored private let evaluate: () async -> Bool
    @ObservationIgnored private static let key = "sc.lock.enabled"

    private(set) var isEnabled: Bool
    private(set) var isLocked = false

    /// True when the device can do biometric/passcode auth.
    var isAvailable: Bool { canEvaluate() }

    init(defaults: UserDefaults = .standard,
         canEvaluate: (() -> Bool)? = nil,
         evaluate: (() async -> Bool)? = nil) {
        self.defaults = defaults
        self.canEvaluate = canEvaluate ?? {
            var err: NSError?
            return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &err)
        }
        self.evaluate = evaluate ?? {
            await withCheckedContinuation { cont in
                LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Snapceipt") { ok, _ in
                    cont.resume(returning: ok)
                }
            }
        }
        self.isEnabled = defaults.bool(forKey: Self.key)
    }

    /// Lock now if the feature is enabled (call on cold launch + background→active).
    func lockIfEnabled() { isLocked = isEnabled }

    /// Attempt to unlock via biometrics; clears the lock on success.
    func unlock() async {
        if await evaluate() { isLocked = false }
    }

    /// Toggle the lock. Turning ON requires biometrics to be available AND a
    /// successful check (so the user can't lock themselves out).
    func setEnabled(_ on: Bool) async {
        if on {
            guard isAvailable, await evaluate() else { isEnabled = false; defaults.set(false, forKey: Self.key); return }
            isEnabled = true
        } else {
            isEnabled = false
            isLocked = false
        }
        defaults.set(isEnabled, forKey: Self.key)
    }
}
