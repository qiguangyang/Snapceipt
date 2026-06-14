import Testing
import Foundation
@testable import Snapceipt

@Suite("Onboarding gate")
struct OnboardingGateTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "sc.test.onboarding.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test("needsOnboarding is true until the flag is set, regardless of profile count")
    func gateFlips() {
        let d = freshDefaults()
        // No profile, never completed -> onboarding.
        #expect(OnboardingGate.needsOnboarding(hasProfile: false, defaults: d) == true)
        // Profile created mid-flow but flag not yet set -> STILL onboarding (priming reachable).
        #expect(OnboardingGate.needsOnboarding(hasProfile: true, defaults: d) == true)
        // Flag set -> shell.
        OnboardingGate.markComplete(defaults: d)
        #expect(OnboardingGate.needsOnboarding(hasProfile: true, defaults: d) == false)
    }

    @Test("a returning user with the flag set never re-onboards")
    func returningUser() {
        let d = freshDefaults()
        OnboardingGate.markComplete(defaults: d)
        #expect(OnboardingGate.needsOnboarding(hasProfile: true, defaults: d) == false)
        #expect(OnboardingGate.needsOnboarding(hasProfile: false, defaults: d) == false)
    }
}
