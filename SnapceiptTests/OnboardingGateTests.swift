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
        // New install, flag never set -> onboarding.
        #expect(OnboardingGate.needsOnboarding(defaults: d) == true)
        // Profile inserted mid-flow but flag not yet set -> STILL onboarding (priming reachable).
        // (hasProfile is no longer a parameter; the flag is the sole authority.)
        #expect(OnboardingGate.needsOnboarding(defaults: d) == true)
        // Flag set -> shell.
        OnboardingGate.markComplete(defaults: d)
        #expect(OnboardingGate.needsOnboarding(defaults: d) == false)
    }

    @Test("a returning user with the flag set never re-onboards")
    func returningUser() {
        let d = freshDefaults()
        OnboardingGate.markComplete(defaults: d)
        #expect(OnboardingGate.needsOnboarding(defaults: d) == false)
    }

    @Test("reset clears the completion flag so onboarding is required again")
    func resetClearsFlag() {
        let d = freshDefaults()
        OnboardingGate.markComplete(defaults: d)
        #expect(OnboardingGate.needsOnboarding(defaults: d) == false)
        OnboardingGate.reset(defaults: d)
        #expect(OnboardingGate.needsOnboarding(defaults: d) == true)
    }
}
