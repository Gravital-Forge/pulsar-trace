import Foundation
import Logging

/// Downloads, verifies, and caches whisper model files (R54c, R54d).
///
/// Models live in `~/Library/Caches/PulsarTrace/models/`. A download:
///   1. resumes from a `.partial` file with an HTTP `Range` request (R54c) so
///      an interrupted 3 GB transfer doesn't restart from byte 0;
///   2. on completion verifies SHA-256 against the pinned hash (R54d) — a
///      mismatch deletes the file and surfaces a retryable error; no corrupt
///      model is ever moved into place;
///   3. on success atomically renames `.partial` → final file and (when an
///      `EventWriter` is supplied) emits `model_downloaded`.
///
/// `ModelStore` is an actor: a model fetch is long-lived and may be triggered
/// from several call sites; serializing keeps two fetches of the same model
/// from racing on the same `.partial` file.
public actor ModelStore {

    public enum ModelStoreError: Error, CustomStringConvertible, Equatable {
        case httpError(Int)
        case hashMismatch(expected: String, actual: String)
        case sizeMismatch(expected: Int, actual: Int)
        case noData

        public var description: String {
            switch self {
            case .httpError(let c): return "model download HTTP status \(c)"
            case .hashMismatch(let e, let a):
                return "model SHA-256 mismatch: expected \(e), got \(a)"
            case .sizeMismatch(let e, let a):
                return "model size mismatch: expected \(e) bytes, got \(a)"
            case .noData: return "model download produced no data"
            }
        }
    }

    /// Decides where a download (re)starts given local `.partial` state and the
    /// known full size (R54c). Pure + total — unit-tested without any network.
    public enum ResumePlan: Equatable, Sendable {
        /// `.partial` already holds the whole, correctly-sized file — skip the
        /// transfer, go straight to verification.
        case alreadyComplete
        /// Start fresh from byte 0 (no/empty/oversized partial).
        case fromStart
        /// Resume with `Range: bytes=<offset>-`.
        case resume(offset: Int)

        /// - Parameters:
        ///   - partialBytes: size of the local `.partial` file (0 if absent).
        ///   - expectedTotal: the pinned full file size.
        public static func plan(partialBytes: Int, expectedTotal: Int) -> ResumePlan {
            if partialBytes <= 0 { return .fromStart }
            if partialBytes == expectedTotal { return .alreadyComplete }
            // A partial larger than the target is corrupt — discard it.
            if partialBytes > expectedTotal { return .fromStart }
            return .resume(offset: partialBytes)
        }
    }

    private let directory: URL
    private let session: URLSession
    private let events: EventWriter?
    private let logger: Logger
    private let maxRetries: Int

    /// - Parameters:
    ///   - directory: model cache directory (default
    ///     `~/Library/Caches/PulsarTrace/models`).
    ///   - events: optional events writer for `model_downloaded`.
    ///   - session: injectable for tests (a local stub server).
    ///   - maxRetries: download attempts before giving up (each retry resumes).
    public init(
        directory: URL? = nil,
        events: EventWriter? = nil,
        session: URLSession = .shared,
        maxRetries: Int = 3,
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) {
        self.directory = directory ?? Self.defaultCacheDirectory()
        self.events = events
        self.session = session
        self.maxRetries = maxRetries
        self.logger = logger
    }

    /// `~/Library/Caches/PulsarTrace/models`.
    public static func defaultCacheDirectory() -> URL {
        let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches
            .appendingPathComponent("PulsarTrace", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    /// Final on-disk URL for a model (whether or not it is downloaded yet).
    public func localURL(for model: WhisperModel) -> URL {
        directory.appendingPathComponent(model.fileName)
    }

    /// True when a verified copy of `model` is already cached.
    ///
    /// "Verified" means present *and* SHA-256-matching: a stale/corrupt cached
    /// file is treated as absent so it gets re-downloaded (R54d).
    public func isCached(_ model: WhisperModel) -> Bool {
        let url = localURL(for: model)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? SHA256Verifier.verify(fileAt: url, matches: model.sha256)) == true
    }

    /// Return a cached, verified model path — downloading it first if needed.
    ///
    /// Idempotent: if the model is already cached and verified, no network call
    /// is made.
    @discardableResult
    public func ensureAvailable(_ model: WhisperModel) async throws -> URL {
        let finalURL = localURL(for: model)
        if isCached(model) {
            logger.notice("whisper model already cached: \(model.name)")
            return finalURL
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        var lastError: Error?
        for attempt in 1...maxRetries {
            do {
                try await downloadAndVerify(model)
                return finalURL
            } catch {
                lastError = error
                logger.warning(
                    "model download attempt \(attempt)/\(self.maxRetries) failed: \(error)")
            }
        }
        throw lastError ?? ModelStoreError.noData
    }

    // MARK: - Private

    /// One download-and-verify attempt. A hash mismatch deletes the file so the
    /// next attempt restarts cleanly (R54d).
    private func downloadAndVerify(_ model: WhisperModel) async throws {
        let finalURL = localURL(for: model)
        let partialURL = finalURL.appendingPathExtension("partial")

        let partialBytes = fileSize(at: partialURL)
        let plan = ResumePlan.plan(
            partialBytes: partialBytes, expectedTotal: model.sizeBytes)

        switch plan {
        case .alreadyComplete:
            logger.notice("model \(model.name): partial is complete, verifying")
        case .fromStart:
            try? FileManager.default.removeItem(at: partialURL)
            try await fetch(model: model, into: partialURL, resumingFrom: 0)
        case .resume(let offset):
            logger.notice("model \(model.name): resuming from byte \(offset)")
            try await fetch(model: model, into: partialURL, resumingFrom: offset)
        }

        // Size gate before the (expensive) hash.
        let finalSize = fileSize(at: partialURL)
        guard finalSize == model.sizeBytes else {
            try? FileManager.default.removeItem(at: partialURL)
            throw ModelStoreError.sizeMismatch(
                expected: model.sizeBytes, actual: finalSize)
        }

        // R54d: verify SHA-256; mismatch → delete + retry.
        let actual = try SHA256Verifier.hexDigest(ofFileAt: partialURL)
        guard actual.caseInsensitiveCompare(model.sha256) == .orderedSame else {
            try? FileManager.default.removeItem(at: partialURL)
            throw ModelStoreError.hashMismatch(
                expected: model.sha256, actual: actual)
        }

        // Atomically move the verified file into place.
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try? FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: partialURL, to: finalURL)

        logger.notice("model \(model.name) downloaded + verified (\(finalSize) bytes)")
        _ = try? await events?.append(ModelDownloadedEvent(
            modelName: model.name,
            sizeBytes: finalSize,
            sha256: model.sha256,
            sourceHost: ModelCatalog.huggingFaceHost
        ))
    }

    /// Fetch `model` into `partialURL`, appending from `offset` via a Range
    /// request when `offset > 0` (R54c).
    private func fetch(model: WhisperModel, into partialURL: URL, resumingFrom offset: Int) async throws {
        var request = URLRequest(url: ModelCatalog.downloadURL(for: model))
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }

        let (tempURL, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        if let http = response as? HTTPURLResponse {
            // 200 = full body, 206 = partial (Range honored). Anything else is
            // an error. If we asked for a Range but got 200, the server sent
            // the whole file — overwrite rather than append.
            guard http.statusCode == 200 || http.statusCode == 206 else {
                throw ModelStoreError.httpError(http.statusCode)
            }
            if offset > 0 && http.statusCode == 200 {
                try? FileManager.default.removeItem(at: partialURL)
                try FileManager.default.moveItem(at: tempURL, to: partialURL)
                return
            }
        }

        if offset > 0, FileManager.default.fileExists(atPath: partialURL.path) {
            // Append the downloaded tail onto the existing partial. Stream it in
            // ~1 MiB chunks so a multi-GB tail (large-v3) is never fully
            // resident in memory at once.
            let handle = try FileHandle(forWritingTo: partialURL)
            defer { try? handle.close() }
            let tailHandle = try FileHandle(forReadingFrom: tempURL)
            defer { try? tailHandle.close() }
            try handle.seekToEnd()
            let chunkSize = 1 << 20  // 1 MiB
            while true {
                let chunk = try tailHandle.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty { break }
                try handle.write(contentsOf: chunk)
            }
        } else {
            try? FileManager.default.removeItem(at: partialURL)
            try FileManager.default.moveItem(at: tempURL, to: partialURL)
        }
    }

    /// File size in bytes, or 0 if the file is absent/unreadable.
    private func fileSize(at url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            .flatMap { $0 } ?? 0
    }
}
