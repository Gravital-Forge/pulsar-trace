// Tests/UnitTests/EventWriterFileLockTests.swift
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import PulsarTraceEngine

@Suite("EventWriter cross-process file lock")
struct EventWriterFileLockTests {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-evtlock-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Regression for the corrupted line observed in events/2026-05-20.jsonl
    /// where a recording_paused event from pulsartrace-capture was clobbered
    /// mid-write by an app_stopped event from pulsartrace-mac. EventWriter is
    /// an actor (serialises within a process) but doesn't lock across
    /// processes — flock(LOCK_EX) closes that gap.
    @Test("append blocks while a foreign fd holds LOCK_EX on the same file")
    func appendHonoursForeignFlock() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = EventWriter(directory: dir)
        await writer.bootstrap()

        let url = await writer.currentFileURL()
        // Foreign fd standing in for a second process. Must be a separate fd —
        // flock on the same fd from the same process is a no-op.
        let foreignFd = open(url.path, O_RDWR)
        #expect(foreignFd >= 0, "foreign open failed: errno \(errno)")
        defer { close(foreignFd) }
        #expect(flock(foreignFd, LOCK_EX) == 0, "foreign flock failed")

        let payload = AppStoppedEvent(version: "test", macosVersion: "test")
        let writeStarted = Date()
        let writeTask = Task { try await writer.append(payload) }

        // Give the actor a chance to enter append(); if it doesn't honour the
        // foreign lock the file will already have data.
        try await Task.sleep(for: .milliseconds(200))
        let mid = try Data(contentsOf: url)
        #expect(mid.isEmpty,
                "EventWriter wrote while a foreign LOCK_EX was held — cross-process lock missing")

        _ = flock(foreignFd, LOCK_UN)
        _ = try await writeTask.value
        let final = try Data(contentsOf: url)
        #expect(final.count > 0, "writer should have proceeded after the lock released")
        let elapsed = Date().timeIntervalSince(writeStarted)
        #expect(elapsed >= 0.2,
                "writer must have actually waited; only \(elapsed)s elapsed")
    }

    /// Regression for position-drift across multiple EventWriters on the same
    /// file. Even with flock, each FileHandle holds its own cached position
    /// from the initial seekToEnd at open — so the second writer's write lands
    /// at the position recorded at open time, overwriting bytes the first
    /// writer just added.
    @Test("two EventWriters on the same dir do not clobber each other's writes")
    func twoWritersDoNotClobber() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = EventWriter(directory: dir)
        let b = EventWriter(directory: dir)
        await a.bootstrap()
        await b.bootstrap()
        let url = await a.currentFileURL()

        // 10 alternating writes. With position drift, b's writes overwrite a's.
        for _ in 0..<10 {
            _ = try await a.append(AppStoppedEvent(version: "A", macosVersion: "test"))
            _ = try await b.append(AppStoppedEvent(version: "B", macosVersion: "test"))
        }

        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 20,
                "expected 20 lines (10 each from A and B), got \(lines.count)")
        for line in lines {
            // Each line must be valid JSON — no partial / clobbered bytes.
            #expect(line.first == "{" && line.last == "}",
                    "line is not a complete JSON object: \(line)")
        }
    }
}
