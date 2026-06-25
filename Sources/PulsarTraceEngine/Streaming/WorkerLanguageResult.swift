import Foundation

/// Carries the decode worker's end-of-stream detected language back to the run
/// teardown, and a liveness timestamp the teardown uses to bound the wait.
///
/// The worker calls `noteProgress()` after every decoded window and
/// `finish(language:)` once it has drained both queues and flushed. Teardown
/// *polls* (it never `await`s the worker Task — a wedged decode is
/// uncancellable, so awaiting it could hang the run forever). The bound is on
/// *inactivity*, not total time: the run stops waiting once the worker has made
/// no progress for the drain timeout. So a slow-but-progressing decode (e.g. a
/// fast-fed fixture, or a decoder catching up on a backlog) runs to
/// completion, while a genuinely wedged decode — no progress at all — releases
/// the run after the timeout. The recording is already safe on disk regardless.
actor WorkerLanguageResult {
    private(set) var language: String?
    private(set) var isFinished = false
    private(set) var lastProgress = ContinuousClock.now

    /// Mark that the worker made forward progress (a window decoded). Keeps the
    /// teardown's inactivity deadline fresh.
    func noteProgress() { lastProgress = ContinuousClock.now }

    /// Reset the inactivity clock to now — call once when the teardown wait
    /// begins so the bound measures inactivity *since teardown started*, not
    /// since run-start. A first/final decode that is slow but progressing then
    /// gets the full `workerDrainTimeout` of grace.
    func armDeadline() { lastProgress = ContinuousClock.now }

    func finish(language: String) {
        self.language = language
        self.isFinished = true
    }
}
