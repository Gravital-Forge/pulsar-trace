// Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobStore.swift
import Foundation

/// JSON-on-disk persistence for the refinement queue (D-Q5).
///
/// One file per job: `<id>.json`. Atomic writes via `AtomicFile` so a crash
/// mid-write cannot corrupt a job descriptor. The actor is the single writer
/// per process; readers see consistent file content (rename-into-place).
public actor RefinementJobStore {

    public enum StoreError: Error, CustomStringConvertible, Equatable {
        case directoryCreateFailed(String)
        case encodeFailed(String)
        case writeFailed(String)
        case decodeFailed(String)

        public var description: String {
            switch self {
            case .directoryCreateFailed(let m): return "queue dir create failed: \(m)"
            case .encodeFailed(let m): return "job encode failed: \(m)"
            case .writeFailed(let m): return "job write failed: \(m)"
            case .decodeFailed(let m): return "job decode failed: \(m)"
            }
        }
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Standard location: `~/Library/Application Support/PulsarTrace/refinement-queue/`.
    public static func standard(paths: AppPaths) -> RefinementJobStore {
        let dir = paths.applicationSupport
            .appendingPathComponent("refinement-queue", isDirectory: true)
        return RefinementJobStore(directory: dir)
    }

    /// Write or overwrite one job.
    public func upsert(_ job: RefinementJob) throws {
        try ensureDirectoryExists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do { data = try encoder.encode(job) }
        catch { throw StoreError.encodeFailed("\(error)") }
        do { _ = try AtomicFile.write(data, to: url(for: job.id)) }
        catch { throw StoreError.writeFailed("\(error)") }
    }

    /// Remove one job's file.
    public func delete(id: String) throws {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// Every persisted job, sorted by `enqueuedAt` ascending.
    public func listAll() throws -> [RefinementJob] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var jobs: [RefinementJob] = []
        for entry in entries where entry.pathExtension == "json" {
            guard let data = try? Data(contentsOf: entry) else { continue }
            // One bad file must not fail the whole scan (parallel to
            // RecordingsScanner — see Sources/PulsarTraceMenuBar/RecordingsScanner.swift).
            guard let job = try? decoder.decode(RefinementJob.self, from: data)
            else { continue }
            jobs.append(job)
        }
        jobs.sort { $0.enqueuedAt < $1.enqueuedAt }
        return jobs
    }

    private func url(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json", isDirectory: false)
    }

    private func ensureDirectoryExists() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw StoreError.directoryCreateFailed("\(error)")
            }
        }
    }
}
