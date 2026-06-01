import Testing
import Foundation
@testable import Snapceipt

@MainActor
@Suite("AppLockController")
struct AppLockControllerTests {
    private func make(enabled: Bool, canEval: Bool, evalResult: Bool) -> AppLockController {
        let defaults = UserDefaults(suiteName: "lock.\(UUID().uuidString)")!
        defaults.set(enabled, forKey: "sc.lock.enabled")
        return AppLockController(defaults: defaults, canEvaluate: { canEval }, evaluate: { evalResult })
    }

    @Test("enabled + available locks on launch and unlocks on success")
    func lockUnlock() async {
        let c = make(enabled: true, canEval: true, evalResult: true)
        c.lockIfEnabled()
        #expect(c.isLocked == true)
        await c.unlock()
        #expect(c.isLocked == false)
    }

    @Test("disabled never locks")
    func disabled() {
        let c = make(enabled: false, canEval: true, evalResult: true)
        c.lockIfEnabled()
        #expect(c.isLocked == false)
    }

    @Test("failed biometric stays locked")
    func failed() async {
        let c = make(enabled: true, canEval: true, evalResult: false)
        c.lockIfEnabled()
        await c.unlock()
        #expect(c.isLocked == true)
    }

    @Test("setEnabled(true) requires a successful check; canEvaluate=false refuses")
    func enabling() async {
        let ok = make(enabled: false, canEval: true, evalResult: true)
        await ok.setEnabled(true)
        #expect(ok.isEnabled == true)

        let noBio = make(enabled: false, canEval: false, evalResult: true)
        #expect(noBio.isAvailable == false)
        await noBio.setEnabled(true)
        #expect(noBio.isEnabled == false)   // refused; no biometry/passcode
    }
}
