import Testing
@testable import PulsarTraceMenuBar

/// Epic 8 — `OnboardingTourViewModel` is a deferred (P2) stub: the tour is
/// never needed (R46 not built).
@Suite("OnboardingTourViewModel (Epic 8)")
@MainActor
struct OnboardingTourViewModelTests {

    @Test("the onboarding tour is never needed (R46 deferred)")
    func tourNeverNeeded() {
        let viewModel = OnboardingTourViewModel()
        #expect(viewModel.isNeeded == false)
    }
}
