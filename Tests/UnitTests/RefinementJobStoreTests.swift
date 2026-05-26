// Tests/UnitTests/RefinementJobStoreTests.swift
import Foundation
import Testing
@testable import PulsarTraceEngine

@Suite("RefinementJobStore")
struct RefinementJobStoreTests {

    /// Fresh temp directory per test.
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-jobstore-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a persisted job is readable back through listAll()")
    func persistAndList() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RefinementJobStore(directory: dir)

        let job = RefinementJob(
            id: "job_01HZ",
            recordingId: "rec_x",
            folderURL: URL(fileURLWithPath: "/tmp/rec"),
            modelName: "base", modelSHA256: "deadbeef",
            trigger: .manual,
            enqueuedAt: Date(timeIntervalSince1970: 1_716_120_000),
            state: .queued)

        try await store.upsert(job)
        let all = try await store.listAll()
        #expect(all.count == 1)
        #expect(all.first == job)
    }

    @Test("upsert overwrites a job with the same id")
    func upsertOverwrites() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RefinementJobStore(directory: dir)

        var job = RefinementJob(
            id: "job_01HZ", recordingId: "rec_x",
            folderURL: URL(fileURLWithPath: "/tmp/rec"),
            modelName: "base", modelSHA256: "deadbeef",
            trigger: .manual, enqueuedAt: Date(), state: .queued)
        try await store.upsert(job)

        job.state = .completed(durationSeconds: 42.0, speakerCount: 2)
        try await store.upsert(job)

        let all = try await store.listAll()
        #expect(all.count == 1)
        #expect(all.first?.state == .completed(durationSeconds: 42.0, speakerCount: 2))
    }

    @Test("delete removes the job's file")
    func deleteRemovesFile() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RefinementJobStore(directory: dir)

        let job = RefinementJob(
            id: "job_01HZ", recordingId: "rec_x",
            folderURL: URL(fileURLWithPath: "/tmp/rec"),
            modelName: "base", modelSHA256: "deadbeef",
            trigger: .manual, enqueuedAt: Date(), state: .queued)
        try await store.upsert(job)
        try await store.delete(id: job.id)
        let all = try await store.listAll()
        #expect(all.isEmpty)
    }

    @Test("pruneTerminal deletes completed/failed/cancelled jobs older than the cutoff")
    func pruneTerminal() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RefinementJobStore(directory: dir)

        let old = Date(timeIntervalSinceNow: -8 * 86400)
        let now = Date()

        let stale = RefinementJob(
            id: "job_old", recordingId: "rec_a",
            folderURL: URL(fileURLWithPath: "/tmp/a"),
            modelName: "base", modelSHA256: "deadbeef",
            trigger: .manual, enqueuedAt: old,
            state: .completed(durationSeconds: 1.0, speakerCount: 1))
        let fresh = RefinementJob(
            id: "job_new", recordingId: "rec_b",
            folderURL: URL(fileURLWithPath: "/tmp/b"),
            modelName: "base", modelSHA256: "deadbeef",
            trigger: .manual, enqueuedAt: now,
            state: .completed(durationSeconds: 1.0, speakerCount: 1))
        let active = RefinementJob(
            id: "job_act", recordingId: "rec_c",
            folderURL: URL(fileURLWithPath: "/tmp/c"),
            modelName: "base", modelSHA256: "deadbeef",
            trigger: .manual, enqueuedAt: old,
            state: .queued)

        try await store.upsert(stale)
        try await store.upsert(fresh)
        try await store.upsert(active)

        try await store.pruneTerminal(olderThanDays: 7, now: { Date() })

        let ids = Set(try await store.listAll().map(\.id))
        #expect(ids == ["job_new", "job_act"])
    }
}
