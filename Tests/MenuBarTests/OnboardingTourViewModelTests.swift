import Testing
@testable import PulsarTraceMenuBar

/// `OnboardingTourViewModel` is a deferred (P2) stub: the tour is
/// never needed (R46 not built).
@Suite("OnboardingTourViewModel")
@MainActor
struct OnboardingTourViewModelTests {

    @Test("the onboarding tour is never needed (R46 deferred)")
    func tourNeverNeeded() {
        let viewModel = OnboardingTourViewModel()
        #expect(viewModel.isNeeded == false)
    }
}
