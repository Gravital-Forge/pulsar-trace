// Tests/MenuBarTests/RefinementJobQueueViewModelTests.swift
import Foundation
import Testing
@testable import PulsarTraceEngine
@testable import PulsarTraceMenuBar

@Suite("RefinementJobQueueViewModel")
@MainActor
struct RefinementJobQueueViewModelTests {

    private func tempStore() -> RefinementJobStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-vm-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return RefinementJobStore(directory: dir)
    }

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

    @Test("enqueueManual sets lastEnqueueError when the queue throws")
    func enqueueErrorSurfaced() async throws {
        // Build a queue whose store points at an unwritable directory.
        // Parent `/dev/null` is a character device, not a directory, so
        // createDirectory under it fails deterministically — gives us a
        // reproducible "store dir is unwritable" without TCC variance.
        let badDir = URL(fileURLWithPath: "/dev/null/pulsartrace-bad-\(UUID().uuidString)")
        let badStore = RefinementJobStore(directory: badDir)
        let queue = RefinementJobQueue(store: badStore, runJob: { _ in })
        let vm = RefinementJobQueueViewModel(queue: queue)

        await vm.enqueueManual(
            folderURL: URL(fileURLWithPath: "/tmp/x"),
            recordingId: "rec_x",
            modelName: "stub",
            modelSHA256: "stub")

        #expect(vm.lastEnqueueError != nil,
                "an unwritable store must surface as lastEnqueueError")
    }

    @Test("enqueueManual clears lastEnqueueError on success")
    func enqueueClearsError() async throws {
        let queue = RefinementJobQueue(store: tempStore(), runJob: { _ in })
        let vm = RefinementJobQueueViewModel(queue: queue)
        vm.lastEnqueueError = "stale"
        await vm.enqueueManual(
            folderURL: URL(fileURLWithPath: "/tmp/x"),
            recordingId: "rec_ok",
            modelName: "stub",
            modelSHA256: "stub")
        #expect(vm.lastEnqueueError == nil)
    }

    @Test("redactHome replaces the user's home directory with ~")
    func redactHomeWorks() {
        let raw = "Could not enqueue refinement: cannot write to \(NSHomeDirectory())/Library/Foo"
        let redacted = RefinementJobQueueViewModel.redactHome(raw)
        #expect(!redacted.contains(NSHomeDirectory()),
                "redactHome must strip the user's home directory from rendered errors")
        #expect(redacted.contains("~/Library/Foo"))
    }

    @Test("onJobTerminated fires for every newly-completed job")
    func onJobTerminatedFires() async throws {
        let queue = RefinementJobQueue(store: tempStore(), runJob: { _ in })
        let vm = RefinementJobQueueViewModel(queue: queue)
        let fired = MainActorBox<[String]>(value: [])
        vm.onJobTerminated = { @MainActor job in
            fired.value.append(job.recordingId)
        }
        // Enqueue + let the worker drain (runJob is a no-op).
        try await queue.enqueueAutoRefine(
            folderURL: URL(fileURLWithPath: "/tmp/a"),
            recordingId: "rec_a", modelName: "stub", modelSHA256: "stub")
        try await queue.enqueueAutoRefine(
            folderURL: URL(fileURLWithPath: "/tmp/b"),
            recordingId: "rec_b", modelName: "stub", modelSHA256: "stub")
        let deadline = Date().addingTimeInterval(2)
        while await queue.snapshot().recent.count < 2, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        await vm.refresh()
        // Both terminations observed exactly once.
        #expect(fired.value.sorted() == ["rec_a", "rec_b"])

        // A second refresh with no new terminal jobs must NOT re-fire.
        fired.value.removeAll()
        await vm.refresh()
        #expect(fired.value.isEmpty)
    }

    /// Captures values across `@MainActor` boundaries in a test.
    @MainActor private final class MainActorBox<T> {
        var value: T
        init(value: T) { self.value = value }
    }
}
