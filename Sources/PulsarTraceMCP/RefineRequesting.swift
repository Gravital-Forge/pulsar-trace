import Foundation

/// Enqueue a (re-)refinement and return immediately (PT-R120). The app forwards
/// to `RefinementJobQueueViewModel.enqueueManual`; the queue dedups so a repeat
/// enqueue for the same recording is a no-op.
// PT-R120
public protocol RefineRequesting: Sendable {
    func requestRefine(folderURL: URL, recordingId: String) async throws
}
