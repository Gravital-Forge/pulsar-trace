import Foundation

/// First-run onboarding tour (PT-R114) — a P2/deferred feature.
///
/// PT-R114 (the guided onboarding tour) is P2 and not yet built. This stub
/// keeps the menubar's wiring complete: `OnboardingTourView` binds to it and,
/// because `isNeeded` is always `false`, the tour never shows. A later change
/// can flesh this out without changing the call sites.
@MainActor
@Observable
public final class OnboardingTourViewModel {

    public init() {}

    /// Whether the onboarding tour should be presented. Always `false` — PT-R114
    /// is deferred (no tour built).
    public var isNeeded: Bool { false }
}
