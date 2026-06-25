import Testing
@testable import PulsarTraceMenuBar

/// `OnboardingTourViewModel` is a deferred (P2) stub: the tour is
/// never needed (PT-R114 not built).
@Suite("OnboardingTourViewModel")
@MainActor
struct OnboardingTourViewModelTests {

    @Test("the onboarding tour is never needed (PT-R114 deferred)")
    func tourNeverNeeded() {
        let viewModel = OnboardingTourViewModel()
        #expect(viewModel.isNeeded == false)
    }
}
