import PulsarTraceMenuBar
import SwiftUI

/// The first-run onboarding tour (PT-R114) — a deferred P2 feature.
///
/// `OnboardingTourViewModel.isNeeded` is always `false`, so this view is never
/// presented. It exists as a stub so the wiring is complete; a later change
/// fleshes it out.
struct OnboardingTourView: View {
    let viewModel: OnboardingTourViewModel

    var body: some View {
        VStack(spacing: 8) {
            Text("Welcome to PulsarTrace")
                .font(.headline)
            Text("The guided tour is coming in a future update.")
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 360)
    }
}
