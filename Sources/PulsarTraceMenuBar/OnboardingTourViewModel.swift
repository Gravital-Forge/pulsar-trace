import Foundation

/// First-run onboarding tour (R46) — a P2/deferred feature.
///
/// R46 (the guided onboarding tour) is P2 and not built in Epic 8. This stub
/// keeps the menubar's wiring complete: `OnboardingTourView` binds to it and,
/// because `isNeeded` is always `false`, the tour never shows. A later epic
/// can flesh this out without changing the call sites.
@MainActor
@Observable
public final class OnboardingTourViewModel {

    public init() {}

    /// Whether the onboarding tour should be presented. Always `false` — R46
    /// is deferred (no tour built).
    public var isNeeded: Bool { false }
}
