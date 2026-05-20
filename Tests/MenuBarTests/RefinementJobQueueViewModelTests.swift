// Tests/MenuBarTests/RefinementJobQueueViewModelTests.swift
import Foundation
import Testing
import PulsarTraceEngine
@testable import PulsarTraceMenuBar

@Suite("RefinementJobQueueViewModel")
@MainActor
struct RefinementJobQueueViewModelTests {

    @Test("snapshot updates propagate to the @Observable VM")
    func snapshotPropagates() async throws {
        let store = RefinementJobStore(directory: FileManager.default
            .temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let queue = RefinementJobQueue(
            store: store, runJob: { _ in })
        try await queue.start()
        let vm = RefinementJobQueueViewModel(queue: queue)
        await vm.refresh()
        #expect(vm.running == nil)
        #expect(vm.queued.isEmpty)
    }
}
