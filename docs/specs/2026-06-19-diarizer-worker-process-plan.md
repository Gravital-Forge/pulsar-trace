# Diarizer Worker Process Implementation Plan

> **SUPERSEDED — IMPLEMENTED THEN REVERTED (2026-06-23).** This worker-process
> design shipped on `fix/live-diarizer-wedge-reclaim` and was then **removed**.
> The un-cancellable ANE hang it defends against was a misdiagnosis: the live
> pass was wedged by a **blocking stderr pipe**, not the ANE (proof in
> `2026-06-18-live-pass-lag-investigation.md` §10), and that is fixed at the
> source by a chunked pipe drain in `RecordOrchestrator`. Live diarization runs
> **in-process** again via `DiarizerEngineRawAdapter` (DECISIONS.md D40). This
> plan is retained for historical context only — **do not implement it.**

> **For agentic workers:** REQUIRED SUB-SKILL: Use pulsartrace-subagent-driven-development (recommended) or pulsartrace-executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the live windowed diarization out of the `pulsartrace-engine` process into its own killable worker process, fed audio over a Unix-domain socket, so a hung/contended ANE `prediction` becomes recoverable by `SIGKILL` (process death releases the un-cancellable leaked ANE call) instead of permanently freezing diarization and starving Parakeet transcription.

**Architecture:** The engine spawns a worker (`pulsartrace-engine --diarizer-worker`). The engine is the socket **server** (binds once, accepts a fresh connection per worker incarnation); the worker is the **client** (connects, loads FluidAudio, loops: read a window of samples → run the raw `DiarizerEngine.diarize(samples:)` → send back raw spans+embeddings). The worker is **stateless** — all cross-window stitching state (`liveSpeakers` centroids, provisional `Them #N` keys, `centroids()`/`modelRevision()`) stays engine-side in `LiveDiarizer`, so a respawned worker loses no identity continuity. A supervisor (`DiarWorkerClient`) enforces a per-window **deadline**: if a window's result does not arrive in time, it `SIGKILL`s the worker, fails the request (the window is dropped — live diarization is best-effort), and respawns with capped exponential backoff. Transcription is in a different process and is unaffected.

**Tech Stack:** Swift 6 concurrency (actors, `CheckedContinuation`), `Foundation.Process`, POSIX `AF_UNIX` sockets (`socket`/`bind`/`listen`/`accept`/`connect`), FluidAudio CoreML diarization, swift-testing.

---

## Background

A FluidAudio embedding `MLModel.prediction` is **synchronous** and, under ANE contention, can hang **indefinitely and deaf to `Task` cancellation** (documented in FluidAudio's own prewarm comment; reproduced in production recording `2026-06-19-21xx`). In-process there is no way to reclaim it — the D42 `DiarGate` reclaim only abandons (leaks) the wedged task; the leaked call keeps pinning the ANE, and under a wedge storm the leaks accumulate until Parakeet decoding also starves (`qSys=qMic=1500`, "recording paused"). A process boundary is the only mechanism that can actually release a wedged ANE call: `SIGKILL` → the kernel tears down the worker's IOKit/XPC connection to the ANE driver → the driver drops the dead client's session.

**Scope:** Live windowed diarization only. The **offline refine-pass diarization** (`DiarizerEngine.diarize(wavPath:)`, run once after recording) is out of scope and unchanged — it runs after live decoding stops, so it does not contend with Parakeet.

**Non-goals (explicitly excluded):** cross-process ANE access coordination; checkpoint/restore of stitch state (unnecessary — stitch state stays engine-side); moving the transcriber to a worker; a separate control socket.

---

## File Structure

**New files (all in the engine target so both the supervisor and the worker mode live in one binary):**

- `Sources/PulsarTraceEngine/Diarization/DiarWindowResult.swift` — the `Codable` wire DTO for a window's raw diarization output (spans + embeddings), plus the worker→engine `DiarWorkerMessage` envelope.
- `Sources/PulsarTraceEngine/Diarization/DiarWorkerProtocol.swift` — frame encode/decode: the engine→worker binary request frame (requestId + Float32 samples) and the worker→engine length-prefixed JSON message frame.
- `Sources/PulsarTraceEngine/Diarization/RawWindowDiarizing.swift` — the narrow protocol `LiveDiarizer` now depends on (`diarizeRawWindow(samples:) -> DiarWindowResult?` + `modelRevision`).
- `Sources/PulsarTraceEngine/Diarization/DiarWorkerConnection.swift` — a thin bidirectional frame transport over a connected fd (blocking-read thread → `AsyncStream<Data>`; `writeAll` for sends), plus a `DiarWorkerConnecting` protocol so tests can inject a `socketpair`-backed fake.
- `Sources/PulsarTraceEngine/Diarization/DiarWorkerServer.swift` — the worker-mode loop: connect to the engine, send `hello(modelRevision)`, then read request frames → `rawDiarizer.diarizeRawWindow` → send `result` frames. Takes a `RawWindowDiarizing` so it is testable without real models.
- `Sources/PulsarTraceEngine/Diarization/DiarWorkerClient.swift` — the supervisor + RPC proxy actor (conforms to `RawWindowDiarizing`): bind/listen/accept the server socket, spawn the worker, run the reader, enforce the per-window deadline, kill+respawn with backoff, shutdown. Behind injectable `DiarWorkerLaunching` for tests.

**Modified files:**

- `Sources/PulsarTraceEngine/Support/AppPaths.swift` — add `diarizerSocketURL(recordingId:)`.
- `Sources/PulsarTraceEngine/Streaming/LiveDiarizer.swift` — depend on `RawWindowDiarizing` instead of `DiarizerEngine`; `stitch` consumes `DiarWindowResult`; drop the in-process `withTaskGroup` window timeout.
- `Sources/PulsarTraceEngine/Streaming/StreamingPipeline.swift` — `Configuration.liveRawDiarizer: (any RawWindowDiarizing)?` replaces `liveDiarizerEngine`; construct `LiveDiarizer` from it.
- `Sources/pulsartrace-engine/main.swift` — add the `--diarizer-worker` mode; in `live()`, spawn a `DiarWorkerClient` and pass it as `liveRawDiarizer` (instead of loading an in-process `DiarizerEngine` for the live path).

**Test files:**

- `Tests/UnitTests/DiarWorkerProtocolTests.swift` — frame + DTO round-trips.
- `Tests/UnitTests/LiveDiarizerStitchTests.swift` — stitch over a fake `RawWindowDiarizing` (no models).
- `Tests/PipelineTests/DiarWorkerClientTests.swift` — the supervisor against a `socketpair`-backed fake worker: normal RPC, hang→deadline→kill→nil→recover, EOF→restart.
- `Tests/PipelineTests/DiarWorkerServerTests.swift` — the worker loop against a fake `RawWindowDiarizing` over a `socketpair`.
- `Tests/PipelineTests/DiarWorkerIntegrationTests.swift` — gated; spawns the **real** worker binary, one round-trip + one kill/restart.

**Build/test reminders (from CLAUDE.md):** run `swift build` / `swift test` with `dangerouslyDisableSandbox: true`, **bare** (no pipes/redirects/`&&`). Verify with narrow filters (`--filter UnitTests`, `--filter DiarWorker`, `--filter LiveRunner`, `--filter Streaming`), never the broad `--filter PipelineTests`.

---

## Task 1: Diarizer socket path

**Files:**
- Modify: `Sources/PulsarTraceEngine/Support/AppPaths.swift` (add after `micSocketURL`, ~line 77-80)
- Test: `Tests/UnitTests/AppPathsTests.swift` (create if absent; otherwise add to the existing AppPaths test suite)

- [ ] **Step 1: Write the failing test**

Add to `Tests/UnitTests/AppPathsTests.swift` (create the file with this content if it does not exist):

```swift
import Testing
import Foundation
@testable import PulsarTraceEngine

@Suite("AppPaths diarizer socket")
struct AppPathsDiarizerSocketTests {
    @Test("diarizer socket path is under the socket dir and stays within the sockaddr_un 104-byte cap")
    func diarizerSocketPath() {
        let paths = AppPaths(home: URL(fileURLWithPath: "/Users/test"))
        let url = paths.diarizerSocketURL(recordingId: "2026-06-19-084407")
        #expect(url.lastPathComponent == "2026-06-19-084407-diar.sock")
        #expect(url.deletingLastPathComponent() == paths.socketDirectory)
        // sockaddr_un.sun_path is capped at 104 bytes incl. NUL on Darwin.
        #expect(url.path.utf8.count < 104)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run (bare, `dangerouslyDisableSandbox: true`): `swift test --filter AppPathsDiarizerSocket`
Expected: FAIL — `value of type 'AppPaths' has no member 'diarizerSocketURL'`.

- [ ] **Step 3: Add the path accessor**

In `Sources/PulsarTraceEngine/Support/AppPaths.swift`, immediately after `micSocketURL(recordingId:)`:

```swift
    /// Per-session Unix-domain socket for the live diarizer worker (D43).
    /// Same `$TMPDIR/PulsarTrace/` directory and 104-byte `sun_path` budget as
    /// the capture sockets (see `socketDirectory`).
    public func diarizerSocketURL(recordingId: String) -> URL {
        socketDirectory.appendingPathComponent("\(recordingId)-diar.sock", isDirectory: false)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AppPathsDiarizerSocket`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/Support/AppPaths.swift Tests/UnitTests/AppPathsTests.swift
git commit -m "feat(diar): add per-session diarizer worker socket path (D43)"
```

---

## Task 2: Wire DTO + message envelope

**Files:**
- Create: `Sources/PulsarTraceEngine/Diarization/DiarWindowResult.swift`
- Test: `Tests/UnitTests/DiarWorkerProtocolTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/UnitTests/DiarWorkerProtocolTests.swift`:

```swift
import Testing
import Foundation
@testable import PulsarTraceEngine

@Suite("DiarWorker wire DTO")
struct DiarWindowResultCodableTests {
    @Test("DiarWindowResult round-trips through JSON")
    func resultRoundTrips() throws {
        let r = DiarWindowResult(
            spans: [.init(speaker: "S1", startMillis: 0, endMillis: 1500),
                    .init(speaker: "S2", startMillis: 1500, endMillis: 3000)],
            embeddings: [.init(speaker: "S1", vector: [0.1, 0.2, 0.3]),
                         .init(speaker: "S2", vector: [0.4, 0.5, 0.6])])
        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(DiarWindowResult.self, from: data)
        #expect(decoded == r)
    }

    @Test("DiarWorkerMessage round-trips both cases")
    func messageRoundTrips() throws {
        let hello = DiarWorkerMessage.hello(modelRevision: "abc123")
        let result = DiarWorkerMessage.result(
            requestId: 42,
            window: DiarWindowResult(spans: [], embeddings: []))
        for m in [hello, result] {
            let data = try JSONEncoder().encode(m)
            #expect(try JSONDecoder().decode(DiarWorkerMessage.self, from: data) == m)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DiarWindowResultCodable`
Expected: FAIL — `cannot find 'DiarWindowResult' in scope`.

- [ ] **Step 3: Create the DTO + envelope**

Create `Sources/PulsarTraceEngine/Diarization/DiarWindowResult.swift`:

```swift
import Foundation

/// The raw, window-local diarization output for one window — the only payload
/// the stateless diarizer worker returns. Times are window-local milliseconds
/// (the engine-side stitcher adds the recording-absolute `windowStart`).
/// Deliberately a flat `Codable` DTO (not the engine's `DiarizationResult`,
/// which is not `Codable`) so it crosses the worker socket as JSON.
public struct DiarWindowResult: Codable, Sendable, Equatable {
    public struct Span: Codable, Sendable, Equatable {
        public let speaker: String       // raw per-window label, e.g. "S1"
        public let startMillis: Int
        public let endMillis: Int
        public init(speaker: String, startMillis: Int, endMillis: Int) {
            self.speaker = speaker
            self.startMillis = startMillis
            self.endMillis = endMillis
        }
    }
    public struct Embedding: Codable, Sendable, Equatable {
        public let speaker: String       // matches Span.speaker
        public let vector: [Float]       // 256-d WeSpeaker; empty if none
        public init(speaker: String, vector: [Float]) {
            self.speaker = speaker
            self.vector = vector
        }
    }
    public let spans: [Span]
    public let embeddings: [Embedding]
    public init(spans: [Span], embeddings: [Embedding]) {
        self.spans = spans
        self.embeddings = embeddings
    }

    public static let empty = DiarWindowResult(spans: [], embeddings: [])
}

/// Worker → engine messages. `hello` is sent once on connect (carrying the
/// model digest the engine needs for the R18 library lookup); `result` carries
/// one window's output, correlated to a request by `requestId`.
public enum DiarWorkerMessage: Codable, Sendable, Equatable {
    case hello(modelRevision: String)
    case result(requestId: UInt64, window: DiarWindowResult)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DiarWindowResultCodable`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/Diarization/DiarWindowResult.swift Tests/UnitTests/DiarWorkerProtocolTests.swift
git commit -m "feat(diar): wire DTO + message envelope for the diarizer worker (D43)"
```

---

## Task 3: Frame codec (length-prefixed request + message frames)

**Files:**
- Create: `Sources/PulsarTraceEngine/Diarization/DiarWorkerProtocol.swift`
- Test: `Tests/UnitTests/DiarWorkerProtocolTests.swift` (append)

The wire framing reuses the proven shape from `IPC/FrameProtocol.swift`: a 4-byte little-endian `UInt32` length prefix, then exactly `length` payload bytes. Two payload shapes:
- **engine→worker request** (samples are large → binary): `UInt64 requestId (LE)` then `Float32 samples (LE)`. `length = 8 + samples.count*4`.
- **worker→engine message** (small, structured → JSON): the `DiarWorkerMessage` JSON bytes. `length = json.count`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/UnitTests/DiarWorkerProtocolTests.swift`:

```swift
@Suite("DiarWorker frame codec")
struct DiarWorkerFrameTests {
    @Test("request frame round-trips requestId + samples")
    func requestFrameRoundTrips() throws {
        let samples: [Float] = [0.0, -1.0, 0.5, 0.25]
        let frame = DiarWorkerProtocol.encodeRequest(requestId: 7, samples: samples)
        // 4-byte length prefix + 8-byte id + 4*4 sample bytes
        #expect(frame.count == 4 + 8 + 16)
        let (len, body) = try DiarWorkerProtocol.splitLengthPrefixed(frame)
        #expect(len == 8 + 16)
        let decoded = try DiarWorkerProtocol.decodeRequest(body)
        #expect(decoded.requestId == 7)
        #expect(decoded.samples == samples)
    }

    @Test("message frame round-trips a result envelope")
    func messageFrameRoundTrips() throws {
        let msg = DiarWorkerMessage.result(
            requestId: 9,
            window: DiarWindowResult(spans: [.init(speaker: "S1", startMillis: 0, endMillis: 10)],
                                     embeddings: []))
        let frame = try DiarWorkerProtocol.encodeMessage(msg)
        let (_, body) = try DiarWorkerProtocol.splitLengthPrefixed(frame)
        #expect(try DiarWorkerProtocol.decodeMessage(body) == msg)
    }

    @Test("a truncated length prefix is reported, not crashed")
    func truncatedPrefixThrows() {
        #expect(throws: (any Error).self) {
            _ = try DiarWorkerProtocol.splitLengthPrefixed(Data([0x01, 0x02]))
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DiarWorkerFrame`
Expected: FAIL — `cannot find 'DiarWorkerProtocol' in scope`.

- [ ] **Step 3: Create the codec**

Create `Sources/PulsarTraceEngine/Diarization/DiarWorkerProtocol.swift`:

```swift
import Foundation

/// Length-prefixed framing for the diarizer-worker socket (D43), mirroring the
/// shape of `IPC/FrameProtocol`: a 4-byte little-endian `UInt32` length, then
/// exactly that many payload bytes. Requests (engine→worker) are binary
/// (requestId + Float32 samples); messages (worker→engine) are JSON-encoded
/// `DiarWorkerMessage`.
public enum DiarWorkerProtocol {

    public enum CodecError: Error, Equatable {
        case shortPrefix
        case shortBody(expected: Int, got: Int)
        case shortRequest
        case oversized(Int)
    }

    /// 1 MiB cap on a single frame body — a request is ~640 KB for a 10 s/16 kHz
    /// window, results are a few KB. Anything larger is a framing error.
    public static let maxBodyBytes = 1 << 20

    // MARK: Encode

    public static func encodeRequest(requestId: UInt64, samples: [Float]) -> Data {
        var body = Data(capacity: 8 + samples.count * 4)
        var id = requestId.littleEndian
        withUnsafeBytes(of: &id) { body.append(contentsOf: $0) }
        for s in samples {
            var bits = s.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { body.append(contentsOf: $0) }
        }
        return prefixed(body)
    }

    public static func encodeMessage(_ message: DiarWorkerMessage) throws -> Data {
        let json = try JSONEncoder().encode(message)
        return prefixed(json)
    }

    private static func prefixed(_ body: Data) -> Data {
        var out = Data(capacity: 4 + body.count)
        var len = UInt32(body.count).littleEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    // MARK: Decode

    /// Split a buffer that begins with a complete length-prefixed frame into
    /// (declaredLength, body). Throws if the prefix or body is short.
    public static func splitLengthPrefixed(_ data: Data) throws -> (length: Int, body: Data) {
        guard data.count >= 4 else { throw CodecError.shortPrefix }
        let len = Int(data.subdata(in: data.startIndex ..< data.startIndex + 4)
            .withUnsafeBytes { $0.load(as: UInt32.self).littleEndian })
        guard len <= maxBodyBytes else { throw CodecError.oversized(len) }
        let bodyStart = data.startIndex + 4
        guard data.count - 4 >= len else {
            throw CodecError.shortBody(expected: len, got: data.count - 4)
        }
        return (len, data.subdata(in: bodyStart ..< bodyStart + len))
    }

    public static func decodeRequest(_ body: Data) throws -> (requestId: UInt64, samples: [Float]) {
        guard body.count >= 8, (body.count - 8) % 4 == 0 else { throw CodecError.shortRequest }
        let id = body.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        let count = (body.count - 8) / 4
        var samples = [Float](repeating: 0, count: count)
        body.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: 8)
            for i in 0 ..< count {
                let bits = base.advanced(by: i * 4).loadUnaligned(as: UInt32.self).littleEndian
                samples[i] = Float(bitPattern: bits)
            }
        }
        return (id, samples)
    }

    public static func decodeMessage(_ body: Data) throws -> DiarWorkerMessage {
        try JSONDecoder().decode(DiarWorkerMessage.self, from: body)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DiarWorkerFrame`
Expected: PASS (all three).

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/Diarization/DiarWorkerProtocol.swift Tests/UnitTests/DiarWorkerProtocolTests.swift
git commit -m "feat(diar): length-prefixed frame codec for the diarizer worker (D43)"
```

---

## Task 4: `RawWindowDiarizing` protocol + refactor `LiveDiarizer` to use it

This is the seam: `LiveDiarizer` stops owning a `DiarizerEngine` and instead depends on a `RawWindowDiarizing` (which the worker client will conform to). The **stitcher stays** in `LiveDiarizer`; `stitch` now consumes a `DiarWindowResult`. The old in-process `withTaskGroup` window timeout is **removed** (the worker client owns timeouts now).

**Files:**
- Create: `Sources/PulsarTraceEngine/Diarization/RawWindowDiarizing.swift`
- Modify: `Sources/PulsarTraceEngine/Streaming/LiveDiarizer.swift`
- Test: `Tests/UnitTests/LiveDiarizerStitchTests.swift`

- [ ] **Step 1: Create the protocol**

Create `Sources/PulsarTraceEngine/Diarization/RawWindowDiarizing.swift`:

```swift
import Foundation

/// The narrow seam `LiveDiarizer` drives raw per-window diarization through
/// (D43). The production conformer is `DiarWorkerClient`, which proxies to a
/// separate killable worker process; a test conformer can be an in-process fake.
///
/// Stateless by contract: it diarizes ONE window of samples and returns the
/// raw, window-local spans + embeddings. All cross-window stitching (stable
/// `Them #N` keys, running centroids) lives in `LiveDiarizer`, so a conformer
/// that is killed and respawned loses no identity state.
public protocol RawWindowDiarizing: Sendable {
    /// Diarize one window of 16 kHz mono Float32 samples. Returns `nil` when no
    /// usable result is available (worker hung/killed/restarting) — the live
    /// pass then degrades for that window, never crashes.
    func diarizeRawWindow(samples: [Float]) async -> DiarWindowResult?

    /// The diarization model's content digest, for the R18 speaker-library
    /// revision scoping. Empty string when unknown (degrades safely).
    func modelRevision() async -> String
}
```

- [ ] **Step 2: Write the failing test**

Create `Tests/UnitTests/LiveDiarizerStitchTests.swift`:

```swift
import Testing
import Foundation
@testable import PulsarTraceEngine

/// A `RawWindowDiarizing` fake that returns a scripted result per call.
actor ScriptedRawDiarizer: RawWindowDiarizing {
    private var queue: [DiarWindowResult?]
    let revision: String
    init(_ queue: [DiarWindowResult?], revision: String = "rev") {
        self.queue = queue
        self.revision = revision
    }
    func diarizeRawWindow(samples: [Float]) async -> DiarWindowResult? {
        queue.isEmpty ? nil : queue.removeFirst()
    }
    func modelRevision() async -> String { revision }
}

@Suite("LiveDiarizer stitching over a raw diarizer")
struct LiveDiarizerStitchTests {
    private func emb(_ v: Float, _ n: Int = 256) -> [Float] { [Float](repeating: v, count: n) }

    @Test("a window's raw spans become recording-absolute stitched spans")
    func stitchesOneWindow() async {
        let raw = DiarWindowResult(
            spans: [.init(speaker: "S1", startMillis: 0, endMillis: 2000)],
            embeddings: [.init(speaker: "S1", vector: emb(1.0))])
        let diarizer = LiveDiarizer(rawDiarizer: ScriptedRawDiarizer([raw]))
        let spans = await diarizer.diarizeWindow(samples: [], windowStart: .seconds(10))
        #expect(spans.count == 1)
        #expect(spans[0].provisionalKey == "Them")            // first speaker → "Them"
        #expect(spans[0].start == .seconds(10))               // windowStart + 0ms
        #expect(spans[0].end == .seconds(12))                 // windowStart + 2000ms
        #expect(await diarizer.centroids()["Them"] == emb(1.0))
    }

    @Test("a nil raw result yields no spans (degraded window)")
    func nilRawResultYieldsEmpty() async {
        let diarizer = LiveDiarizer(rawDiarizer: ScriptedRawDiarizer([nil]))
        let spans = await diarizer.diarizeWindow(samples: [], windowStart: .seconds(5))
        #expect(spans.isEmpty)
    }

    @Test("modelRevision is read from the raw diarizer")
    func modelRevisionPassThrough() async {
        let diarizer = LiveDiarizer(rawDiarizer: ScriptedRawDiarizer([], revision: "digest-xyz"))
        #expect(await diarizer.modelRevision() == "digest-xyz")
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter LiveDiarizerStitch`
Expected: FAIL — `LiveDiarizer` has no `init(rawDiarizer:)`.

- [ ] **Step 4: Refactor `LiveDiarizer`**

In `Sources/PulsarTraceEngine/Streaming/LiveDiarizer.swift`:

(a) Replace the stored engine + inits. Change:

```swift
    private let engine: DiarizerEngine?
    private let configuration: Configuration
    private let logger: Logger
    private var windowCounter = 0
```
to:
```swift
    private let rawDiarizer: (any RawWindowDiarizing)?
    private let logger: Logger
    private var windowCounter = 0
```

Replace the two `init`s (the `testSeamLogger` one and the `public init(engine:configuration:logger:)`) with:

```swift
    /// Test seam: a diarizer with no raw backend — `diarizeWindow` returns `[]`;
    /// `_seedForTesting` + `centroids()`/`modelRevision()` only.
    init(testSeamLogger logger: Logger = Logger(label: LogSubsystem.engine)) {
        self.rawDiarizer = nil
        self.logger = logger
    }

    public init(
        rawDiarizer: any RawWindowDiarizing,
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) {
        self.rawDiarizer = rawDiarizer
        self.logger = logger
    }
```

(Delete the `Configuration` struct and its `windowTimeout` — the worker client owns timeouts now. If anything else references `LiveDiarizer.Configuration`, it is only the old `StreamingPipeline` wiring, replaced in Task 7.)

(b) Replace `diarizeWindow` (the whole `withTaskGroup` body) with:

```swift
    public func diarizeWindow(
        samples: [Float],
        windowStart: Duration
    ) async -> [LiveSpeakerSpan] {
        guard let rawDiarizer else { return [] }
        windowCounter += 1
        guard let raw = await rawDiarizer.diarizeRawWindow(samples: samples) else {
            // Worker hung/killed/restarting — this window degrades to no spans.
            return []
        }
        return stitch(result: raw, windowStart: windowStart)
    }
```

(c) Change `stitch` to consume `DiarWindowResult`. Replace its signature and the two time conversions:

```swift
    private func stitch(
        result: DiarWindowResult, windowStart: Duration
    ) -> [LiveSpeakerSpan] {
        let embeddingByLabel = Dictionary(
            result.embeddings.map { ($0.speaker, $0.vector) },
            uniquingKeysWith: { first, _ in first })

        var keyByRawLabel: [String: String] = [:]
        for (rawLabel, vector) in embeddingByLabel.sorted(by: { $0.key < $1.key }) {
            keyByRawLabel[rawLabel] = stitchKey(for: vector)
        }

        var out: [LiveSpeakerSpan] = []
        for span in result.spans {
            let key = keyByRawLabel[span.speaker]
                ?? fallbackKey(forRawLabel: span.speaker)
            out.append(LiveSpeakerSpan(
                provisionalKey: key,
                start: windowStart + .milliseconds(span.startMillis),
                end: windowStart + .milliseconds(span.endMillis),
                embedding: embeddingByLabel[span.speaker] ?? []))
        }
        return out
    }
```

(d) Change `modelRevision()` to read the raw diarizer:

```swift
    public func modelRevision() async -> String {
        if let seededModelRevision { return seededModelRevision }
        if let rawDiarizer { return await rawDiarizer.modelRevision() }
        return ""
    }
```

Leave `centroids()`, `stitchKey`, `fallbackKey`, `provisionalKey`, `liveSpeakers`, `fallbackByRaw`, `_seedForTesting`, `stitchThreshold`, and the `LiveDiarizing` protocol conformance unchanged. (Remove the now-unused `import` of nothing; `DiarizationResult` is no longer referenced here.)

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter LiveDiarizerStitch`
Expected: PASS (all three).

- [ ] **Step 6: Confirm nothing else broke yet**

Run: `swift build`
Expected: FAILS only in `StreamingPipeline.swift` / `main.swift` (they still reference the old `LiveDiarizer(engine:)` / `liveDiarizerEngine`). That is expected — fixed in Task 7. Do **not** fix them here.

If `swift build` reports errors **only** in `StreamingPipeline.swift` and `Sources/pulsartrace-engine/main.swift`, proceed. If it reports errors elsewhere, fix those (a missed reference to `LiveDiarizer.Configuration` or `engine:`).

- [ ] **Step 7: Commit**

```bash
git add Sources/PulsarTraceEngine/Diarization/RawWindowDiarizing.swift Sources/PulsarTraceEngine/Streaming/LiveDiarizer.swift Tests/UnitTests/LiveDiarizerStitchTests.swift
git commit -m "refactor(diar): LiveDiarizer stitches over RawWindowDiarizing; drop in-process engine + window timeout (D43)"
```

---

## Task 5: Bidirectional frame connection over an fd

A thin transport: given a connected fd, expose an `AsyncStream<Data>` of inbound frame **bodies** (a blocking read thread reassembles length-prefixed frames, like `IPC/FrameDescriptorReader`) and a `send(_:)` that `writeAll`s a pre-framed `Data`. Behind a `DiarWorkerConnecting` protocol so tests inject a `socketpair`-backed fake.

**Files:**
- Create: `Sources/PulsarTraceEngine/Diarization/DiarWorkerConnection.swift`
- Test: `Tests/PipelineTests/DiarWorkerConnectionTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/PipelineTests/DiarWorkerConnectionTests.swift`:

```swift
import Testing
import Foundation
@testable import PulsarTraceEngine
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

@Suite("DiarWorkerConnection over a socketpair")
struct DiarWorkerConnectionTests {
    /// Returns two connected fds via socketpair(AF_UNIX, SOCK_STREAM).
    private func pair() -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        let rc = socketpair(AF_UNIX, sockStreamType, 0, &fds)
        #expect(rc == 0)
        return (fds[0], fds[1])
    }

    @Test("frames written on one end arrive whole on the other, in order")
    func framesRoundTrip() async throws {
        let (a, b) = pair()
        let writer = DiarWorkerConnection(fd: a)
        let reader = DiarWorkerConnection(fd: b)

        let f1 = DiarWorkerProtocol.encodeRequest(requestId: 1, samples: [1, 2])
        let f2 = DiarWorkerProtocol.encodeRequest(requestId: 2, samples: [3])
        try writer.send(f1)
        try writer.send(f2)

        var bodies: [Data] = []
        for await body in reader.inboundBodies {
            bodies.append(body)
            if bodies.count == 2 { break }
        }
        #expect(try DiarWorkerProtocol.decodeRequest(bodies[0]).requestId == 1)
        #expect(try DiarWorkerProtocol.decodeRequest(bodies[1]).requestId == 2)
        writer.close()
        reader.close()
    }

    @Test("closing the peer ends the inbound stream")
    func peerCloseEndsStream() async throws {
        let (a, b) = pair()
        let writer = DiarWorkerConnection(fd: a)
        let reader = DiarWorkerConnection(fd: b)
        writer.close()                 // peer hangs up
        var count = 0
        for await _ in reader.inboundBodies { count += 1 }
        #expect(count == 0)            // stream finishes, loop exits
        reader.close()
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DiarWorkerConnection`
Expected: FAIL — `cannot find 'DiarWorkerConnection'` / `cannot find 'sockStreamType'`.

- [ ] **Step 3: Implement the connection**

Create `Sources/PulsarTraceEngine/Diarization/DiarWorkerConnection.swift`. (The blocking read loop mirrors `IPC/FrameDescriptorReader.readLoop`; the `writeAll` mirrors `CaptureSocketServer.writeAll`. `sockStreamType` papers over the `SOCK_STREAM` type difference between Glibc (`Int32`) and Darwin (`__DARWIN_C_SOURCE` enum).)

```swift
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// `SOCK_STREAM` as the `Int32` the C `socket`/`socketpair` calls want, across
/// Darwin (where it is a non-`Int32` constant) and Glibc.
public let sockStreamType: Int32 = Int32(SOCK_STREAM.rawValue)

/// What `DiarWorkerClient`/`DiarWorkerServer` use to talk to each other —
/// abstracted so tests can substitute a `socketpair`-backed fake (D43).
public protocol DiarWorkerConnecting: Sendable {
    /// Send one already-length-prefixed frame. Throws on a broken pipe.
    func send(_ frame: Data) throws
    /// Inbound frame **bodies** (length prefix already stripped). Finishes on
    /// EOF / peer close.
    var inboundBodies: AsyncStream<Data> { get }
    func close()
}

/// A bidirectional length-prefixed frame transport over a connected fd. A
/// dedicated blocking-read thread reassembles frames into `inboundBodies`;
/// `send` writes on the caller's thread under a lock.
public final class DiarWorkerConnection: DiarWorkerConnecting, @unchecked Sendable {
    private let fd: Int32
    private let writeLock = NSLock()
    private var closed = false
    public let inboundBodies: AsyncStream<Data>
    private let finish: @Sendable () -> Void

    public init(fd: Int32) {
        self.fd = fd
        var cont: AsyncStream<Data>.Continuation!
        self.inboundBodies = AsyncStream { cont = $0 }
        let c = cont!
        self.finish = { c.finish() }
        Thread.detachNewThread { [fd] in
            DiarWorkerConnection.readLoop(fd: fd, yield: { c.yield($0) }, finish: { c.finish() })
        }
    }

    public func send(_ frame: Data) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        guard !closed else { throw DiarWorkerProtocol.CodecError.shortPrefix }
        try frame.withUnsafeBytes { raw in
            var off = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while off < raw.count {
                let n = write(fd, base + off, raw.count - off)
                if n > 0 { off += n; continue }
                if n == -1 && errno == EINTR { continue }
                throw DiarWorkerConnectionError.writeFailed(errno)
            }
        }
    }

    public func close() {
        writeLock.lock(); let already = closed; closed = true; writeLock.unlock()
        if !already { _ = Foundation.close(fd) }
        finish()
    }

    /// Blocking read loop: read 4-byte LE length, then exactly `length` bytes,
    /// yield the body. Clean EOF or any error finishes the stream.
    private static func readLoop(fd: Int32, yield: (Data) -> Void, finish: () -> Void) {
        func readExactly(_ count: Int) -> Data? {
            guard count >= 0, count <= DiarWorkerProtocol.maxBodyBytes else { return nil }
            var buf = Data(count: count)
            if count == 0 { return buf }
            var got = 0
            let ok = buf.withUnsafeMutableBytes { raw -> Bool in
                let base = raw.bindMemory(to: UInt8.self).baseAddress!
                while got < count {
                    let n = read(fd, base + got, count - got)
                    if n > 0 { got += n; continue }
                    if n == 0 { return false }                 // EOF
                    if n == -1 && errno == EINTR { continue }
                    return false
                }
                return true
            }
            return ok ? buf : nil
        }
        while true {
            guard let prefix = readExactly(4) else { break }
            let len = Int(prefix.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian })
            guard len >= 0, len <= DiarWorkerProtocol.maxBodyBytes, let body = readExactly(len) else { break }
            yield(body)
        }
        finish()
    }
}

public enum DiarWorkerConnectionError: Error, Equatable {
    case writeFailed(Int32)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DiarWorkerConnection`
Expected: PASS (both).

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/Diarization/DiarWorkerConnection.swift Tests/PipelineTests/DiarWorkerConnectionTests.swift
git commit -m "feat(diar): bidirectional frame connection over an fd (D43)"
```

---

## Task 6: The worker server loop

The worker's run loop, independent of how the socket was established and of the real models (it takes a `RawWindowDiarizing` and a `DiarWorkerConnecting`). On start it sends `hello(modelRevision)`, then for each inbound request frame it diarizes and sends back a `result`.

**Files:**
- Create: `Sources/PulsarTraceEngine/Diarization/DiarWorkerServer.swift`
- Test: `Tests/PipelineTests/DiarWorkerServerTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/PipelineTests/DiarWorkerServerTests.swift`:

```swift
import Testing
import Foundation
@testable import PulsarTraceEngine
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

@Suite("DiarWorkerServer loop")
struct DiarWorkerServerTests {
    private func pair() -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        _ = socketpair(AF_UNIX, sockStreamType, 0, &fds)
        return (fds[0], fds[1])
    }

    @Test("server sends hello then a result per request")
    func helloThenResults() async throws {
        let (engineFd, workerFd) = pair()
        let engine = DiarWorkerConnection(fd: engineFd)
        let workerConn = DiarWorkerConnection(fd: workerFd)

        let scripted = ScriptedRawDiarizer(
            [DiarWindowResult(spans: [.init(speaker: "S1", startMillis: 0, endMillis: 5)],
                              embeddings: [.init(speaker: "S1", vector: [0.5])])],
            revision: "rev-1")
        let server = DiarWorkerServer(connection: workerConn, rawDiarizer: scripted)
        let serverTask = Task { await server.run() }

        // Send one request.
        try engine.send(DiarWorkerProtocol.encodeRequest(requestId: 11, samples: [0, 0, 0]))

        var got: [DiarWorkerMessage] = []
        for await body in engine.inboundBodies {
            got.append(try DiarWorkerProtocol.decodeMessage(body))
            if got.count == 2 { break }
        }
        #expect(got[0] == .hello(modelRevision: "rev-1"))
        #expect(got[1] == .result(
            requestId: 11,
            window: DiarWindowResult(spans: [.init(speaker: "S1", startMillis: 0, endMillis: 5)],
                                     embeddings: [.init(speaker: "S1", vector: [0.5])])))
        serverTask.cancel()
        engine.close(); workerConn.close()
    }
}
```

(`ScriptedRawDiarizer` is defined in `LiveDiarizerStitchTests.swift`; if test targets don't share helpers, copy it into this file.)

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DiarWorkerServer`
Expected: FAIL — `cannot find 'DiarWorkerServer'`.

- [ ] **Step 3: Implement the server**

Create `Sources/PulsarTraceEngine/Diarization/DiarWorkerServer.swift`:

```swift
import Foundation
import Logging

/// The diarizer worker's run loop (D43). Stateless: sends `hello` once, then
/// for each request frame runs the raw diarizer and replies with `result`.
/// A hung `diarizeRawWindow` simply blocks this loop forever — by design: the
/// engine supervisor enforces the deadline and `SIGKILL`s this process, which
/// is the only thing that frees a wedged ANE call.
public struct DiarWorkerServer: Sendable {
    private let connection: any DiarWorkerConnecting
    private let rawDiarizer: any RawWindowDiarizing
    private let logger: Logger

    public init(
        connection: any DiarWorkerConnecting,
        rawDiarizer: any RawWindowDiarizing,
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) {
        self.connection = connection
        self.rawDiarizer = rawDiarizer
        self.logger = logger
    }

    public func run() async {
        let revision = await rawDiarizer.modelRevision()
        do {
            try connection.send(try DiarWorkerProtocol.encodeMessage(.hello(modelRevision: revision)))
        } catch {
            logger.error("diar worker: failed to send hello: \(error)")
            return
        }
        for await body in connection.inboundBodies {
            let request: (requestId: UInt64, samples: [Float])
            do {
                request = try DiarWorkerProtocol.decodeRequest(body)
            } catch {
                logger.error("diar worker: bad request frame: \(error)")
                continue
            }
            let window = await rawDiarizer.diarizeRawWindow(samples: request.samples) ?? .empty
            do {
                try connection.send(try DiarWorkerProtocol.encodeMessage(
                    .result(requestId: request.requestId, window: window)))
            } catch {
                logger.error("diar worker: failed to send result: \(error)")
                return
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DiarWorkerServer`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/Diarization/DiarWorkerServer.swift Tests/PipelineTests/DiarWorkerServerTests.swift
git commit -m "feat(diar): stateless diarizer worker run loop (D43)"
```

---

## Task 7: The supervisor (`DiarWorkerClient`) — deadline, kill, respawn

The heart of the change. An actor that owns a worker's lifecycle behind an injectable `DiarWorkerLaunching`, enforces a per-window deadline, kills+respawns on hang/EOF with capped exponential backoff, and conforms to `RawWindowDiarizing`.

**Critical correctness note:** do **not** await the response inside a `withTaskGroup` whose other child is the deadline — that reintroduces the exact reaping-hang this whole project is fixing (the group can't return while a child awaits an un-resumed continuation). Instead register a `CheckedContinuation` in a dictionary keyed by `requestId`; it is resumed by **whichever comes first** — the reader (on a `result`) or the deadline task (with `nil`) — and the loser is a no-op because the entry is removed on first resume.

**Files:**
- Create: `Sources/PulsarTraceEngine/Diarization/DiarWorkerClient.swift`
- Test: `Tests/PipelineTests/DiarWorkerClientTests.swift`

- [ ] **Step 1: Write the failing tests (the crux)**

Create `Tests/PipelineTests/DiarWorkerClientTests.swift`:

```swift
import Testing
import Foundation
@testable import PulsarTraceEngine
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// A fake launcher backed by a socketpair + an in-process worker task whose
/// "hang" behaviour is scriptable. Each `launch()` makes a fresh pair and a
/// fresh worker; `kill` cancels the worker task and closes its end (modelling
/// SIGKILL → the worker's ANE work is "released"). Tracks launch/kill counts.
actor FakeWorkerLauncher: DiarWorkerLaunching {
    enum Behaviour: Sendable { case respond; case hang }
    private var behaviours: [Behaviour]          // one per launch, consumed in order
    private(set) var launches = 0
    private(set) var kills = 0
    init(_ behaviours: [Behaviour]) { self.behaviours = behaviours }

    func launch() async throws -> DiarWorkerHandle {
        launches += 1
        let behaviour = behaviours.isEmpty ? .respond : behaviours.removeFirst()
        var fds: [Int32] = [0, 0]
        _ = socketpair(AF_UNIX, sockStreamType, 0, &fds)
        let engineConn = DiarWorkerConnection(fd: fds[0])
        let workerConn = DiarWorkerConnection(fd: fds[1])
        // In-process fake worker: hello, then echo a result per request unless hanging.
        let worker = Task {
            try? workerConn.send(try DiarWorkerProtocol.encodeMessage(.hello(modelRevision: "rev")))
            for await body in workerConn.inboundBodies {
                guard behaviour == .respond,
                      let req = try? DiarWorkerProtocol.decodeRequest(body) else { continue }
                let result = DiarWorkerMessage.result(
                    requestId: req.requestId,
                    window: DiarWindowResult(spans: [.init(speaker: "S1", startMillis: 0, endMillis: 1)],
                                             embeddings: []))
                try? workerConn.send(try DiarWorkerProtocol.encodeMessage(result))
            }
        }
        return DiarWorkerHandle(
            connection: engineConn,
            modelRevision: "rev",
            kill: { [weak self] in worker.cancel(); workerConn.close(); engineConn.close()
                    Task { await self?.bumpKills() } },
            awaitExit: { _ = await worker.result })
    }
    func bumpKills() { kills += 1 }
}

@Suite("DiarWorkerClient supervisor", .serialized)
struct DiarWorkerClientTests {
    @Test("a normal window returns the worker's result")
    func normalRPC() async throws {
        let launcher = FakeWorkerLauncher([.respond])
        let client = DiarWorkerClient(launcher: launcher, deadline: .milliseconds(500), restartBackoff: .zero)
        await client.start()
        let r = await client.diarizeRawWindow(samples: [0, 0, 0])
        #expect(r?.spans.first?.speaker == "S1")
        #expect(await client.modelRevision() == "rev")
        await client.shutdown()
    }

    @Test("a hung worker hits the deadline, is killed, and the NEXT window recovers")
    func hangThenRecover() async throws {
        // Launch 1 hangs; launch 2 (after kill+respawn) responds.
        let launcher = FakeWorkerLauncher([.hang, .respond])
        let client = DiarWorkerClient(launcher: launcher, deadline: .milliseconds(200), restartBackoff: .zero)
        await client.start()

        let first = await client.diarizeRawWindow(samples: [0])     // hangs → deadline → nil
        #expect(first == nil)
        #expect(await launcher.kills >= 1)                          // the hung worker was killed

        // Give the async respawn a moment, then a fresh window must succeed.
        try await Task.sleep(for: .milliseconds(300))
        let second = await client.diarizeRawWindow(samples: [0])
        #expect(second?.spans.first?.speaker == "S1")
        #expect(await launcher.launches >= 2)                       // respawned
        await client.shutdown()
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DiarWorkerClient`
Expected: FAIL — `cannot find 'DiarWorkerClient' / 'DiarWorkerLaunching' / 'DiarWorkerHandle'`.

- [ ] **Step 3: Implement the supervisor**

Create `Sources/PulsarTraceEngine/Diarization/DiarWorkerClient.swift`:

```swift
import Foundation
import Logging

/// Spawns and supervises one diarizer worker incarnation. Abstracted so tests
/// substitute an in-process fake (D43).
public protocol DiarWorkerLaunching: Sendable {
    func launch() async throws -> DiarWorkerHandle
}

/// A live worker incarnation: its connection, the model digest from its `hello`,
/// and handles to kill it (SIGKILL) and await its exit.
public struct DiarWorkerHandle: Sendable {
    public let connection: any DiarWorkerConnecting
    public let modelRevision: String
    public let kill: @Sendable () -> Void
    public let awaitExit: @Sendable () async -> Void
    public init(connection: any DiarWorkerConnecting, modelRevision: String,
                kill: @escaping @Sendable () -> Void, awaitExit: @escaping @Sendable () async -> Void) {
        self.connection = connection; self.modelRevision = modelRevision
        self.kill = kill; self.awaitExit = awaitExit
    }
}

/// Supervisor + RPC proxy. Conforms to `RawWindowDiarizing`: `diarizeRawWindow`
/// ships the window to the worker and awaits the reply under a deadline; on
/// timeout (or EOF) it kills + respawns the worker and returns `nil` for that
/// window. A killed worker's wedged ANE call dies with the process.
public actor DiarWorkerClient: RawWindowDiarizing {
    private let launcher: any DiarWorkerLaunching
    private let deadline: Duration
    private let restartBackoff: Duration
    private let backoffCap: Duration
    private let logger: Logger

    private var handle: DiarWorkerHandle?
    private var readerTask: Task<Void, Never>?
    private var pending: [UInt64: CheckedContinuation<DiarWindowResult?, Never>] = [:]
    private var nextId: UInt64 = 0
    private var revision = ""
    private var consecutiveRestarts = 0
    private var restarting = false
    private var shuttingDown = false

    public init(
        launcher: any DiarWorkerLaunching,
        deadline: Duration = .seconds(2),
        restartBackoff: Duration = .milliseconds(250),
        backoffCap: Duration = .seconds(10),
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) {
        self.launcher = launcher
        self.deadline = deadline
        self.restartBackoff = restartBackoff
        self.backoffCap = backoffCap
        self.logger = logger
    }

    public func start() async { await bringUp() }

    public func modelRevision() async -> String { revision }

    public func diarizeRawWindow(samples: [Float]) async -> DiarWindowResult? {
        guard !shuttingDown, let handle, !restarting else { return nil }
        let id = nextId; nextId &+= 1

        let frame = DiarWorkerProtocol.encodeRequest(requestId: id, samples: samples)
        do { try handle.connection.send(frame) }
        catch { await restart(reason: "send failed: \(error)"); return nil }

        // Resolve via the reader OR the deadline — whichever first. No task group
        // awaits the reply, so an un-resumed reply can never wedge this call.
        let result: DiarWindowResult? = await withCheckedContinuation { cont in
            pending[id] = cont
            scheduleDeadline(for: id)
        }
        if result != nil { consecutiveRestarts = 0 }   // a real success resets backoff
        return result
    }

    public func shutdown() async {
        shuttingDown = true
        readerTask?.cancel()
        handle?.kill()
        await handle?.awaitExit()
        failAllPending()
        handle = nil
    }

    // MARK: - Internals

    private func scheduleDeadline(for id: UInt64) {
        Task { [deadline] in
            try? await Task.sleep(for: deadline)
            await self.deadlineFired(id: id)
        }
    }

    private func deadlineFired(id: UInt64) async {
        guard let cont = pending.removeValue(forKey: id) else { return }  // reply already won
        cont.resume(returning: nil)
        logger.notice("diar worker: window deadline exceeded — killing + respawning")
        await restart(reason: "deadline")
    }

    private func bringUp() async {
        guard !shuttingDown else { return }
        do {
            let h = try await launcher.launch()
            handle = h
            revision = h.modelRevision
            startReader(for: h)
        } catch {
            logger.error("diar worker: launch failed: \(error)")
        }
    }

    private func startReader(for h: DiarWorkerHandle) {
        readerTask = Task {
            for await body in h.connection.inboundBodies {
                guard let msg = try? DiarWorkerProtocol.decodeMessage(body) else { continue }
                if case let .result(requestId, window) = msg {
                    await self.deliver(requestId: requestId, window: window)
                }
                // `hello` is consumed by the launcher before handing us the handle.
            }
            await self.readerEnded()      // EOF / worker exited unexpectedly
        }
    }

    private func deliver(requestId: UInt64, window: DiarWindowResult) {
        if let cont = pending.removeValue(forKey: requestId) { cont.resume(returning: window) }
    }

    private func readerEnded() async {
        guard !shuttingDown, !restarting else { return }
        await restart(reason: "worker connection closed")
    }

    private func restart(reason: String) async {
        guard !shuttingDown, !restarting else { return }
        restarting = true
        logger.notice("diar worker: restarting (\(reason))")
        readerTask?.cancel()
        handle?.kill()
        await handle?.awaitExit()
        handle = nil
        failAllPending()

        consecutiveRestarts += 1
        let delay = backoff(consecutiveRestarts)
        if delay > .zero { try? await Task.sleep(for: delay) }

        restarting = false
        await bringUp()
    }

    private func failAllPending() {
        let conts = pending.values
        pending.removeAll()
        for c in conts { c.resume(returning: nil) }
    }

    private func backoff(_ n: Int) -> Duration {
        // base * 2^(n-1), capped. n starts at 1.
        let capMs = backoffCap.milliseconds
        let baseMs = restartBackoff.milliseconds
        guard baseMs > 0 else { return .zero }
        let shifted = baseMs * (1 << min(n - 1, 20))
        return .milliseconds(min(shifted, capMs))
    }
}

private extension Duration {
    var milliseconds: Int {
        let c = components
        return Int(c.seconds) * 1000 + Int(c.attoseconds / 1_000_000_000_000_000)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter DiarWorkerClient`
Expected: PASS (both `normalRPC` and `hangThenRecover`). The `hangThenRecover` test is the process-level analogue of the D42 recovery test — it proves a hung worker is killed and the next window recovers.

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/Diarization/DiarWorkerClient.swift Tests/PipelineTests/DiarWorkerClientTests.swift
git commit -m "feat(diar): supervisor with per-window deadline + kill/respawn (D43)"
```

---

## Task 8: Real process launcher + `--diarizer-worker` mode

Now the real `DiarWorkerLaunching` (spawn the engine binary in worker mode, bind/listen/accept the engine-side socket, read `hello`) and the worker entry point that loads the real `DiarizerEngine`.

**Files:**
- Create: `Sources/PulsarTraceEngine/Diarization/DiarWorkerProcessLauncher.swift`
- Create: `Sources/PulsarTraceEngine/Diarization/DiarizerEngineRawAdapter.swift`
- Modify: `Sources/pulsartrace-engine/main.swift`

- [ ] **Step 1: Adapter — `DiarizerEngine` as `RawWindowDiarizing`**

The worker runs the real `DiarizerEngine`. Wrap it to produce `DiarWindowResult`. Create `Sources/PulsarTraceEngine/Diarization/DiarizerEngineRawAdapter.swift`:

```swift
import Foundation

/// Adapts the in-process FluidAudio `DiarizerEngine` to `RawWindowDiarizing`,
/// converting its `DiarizationResult` to the flat wire DTO. Used inside the
/// worker process (D43).
public struct DiarizerEngineRawAdapter: RawWindowDiarizing {
    private let engine: DiarizerEngine
    public init(engine: DiarizerEngine) { self.engine = engine }

    public func diarizeRawWindow(samples: [Float]) async -> DiarWindowResult? {
        guard let result = try? await engine.diarize(samples: samples) else { return nil }
        let spans = result.spans.map {
            DiarWindowResult.Span(
                speaker: $0.speaker,
                startMillis: $0.start.milliseconds,
                endMillis: $0.end.milliseconds)
        }
        let embeddings = result.embeddings.map {
            DiarWindowResult.Embedding(speaker: $0.speaker, vector: $0.vector)
        }
        return DiarWindowResult(spans: spans, embeddings: embeddings)
    }

    public func modelRevision() async -> String { engine.modelRevision }
}

extension Duration {
    /// Whole milliseconds (truncating). Used to flatten span times for the wire.
    var milliseconds: Int {
        let c = components
        return Int(c.seconds) * 1000 + Int(c.attoseconds / 1_000_000_000_000_000)
    }
}
```

(If `Duration.milliseconds` was already added `private` in Task 7's file, make that one `private` and keep this `internal`/`public` extension as the single shared definition — Swift will error on a duplicate. Resolution: delete the `private extension Duration` block at the bottom of `DiarWorkerClient.swift` and rely on this `extension Duration` (same module). Re-run `swift test --filter DiarWorkerClient` to confirm still green.)

- [ ] **Step 2: Commit the adapter**

```bash
git add Sources/PulsarTraceEngine/Diarization/DiarizerEngineRawAdapter.swift Sources/PulsarTraceEngine/Diarization/DiarWorkerClient.swift
git commit -m "feat(diar): DiarizerEngine→RawWindowDiarizing adapter; share Duration.milliseconds (D43)"
```

- [ ] **Step 3: Real launcher**

Create `Sources/PulsarTraceEngine/Diarization/DiarWorkerProcessLauncher.swift`. The engine is the **server**: bind+listen the socket once (reused across launches), then per `launch()` spawn the worker and `accept()` its connection, read its `hello`. (POSIX bind/listen/accept boilerplate mirrors `PulsarTraceCapture/CaptureSocketServer.start`; the `Process` spawn + exit-wait mirrors `Engine/RecordOrchestrator` (`Process`, `terminationHandler`).)

```swift
import Foundation
import Logging
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Spawns `pulsartrace-engine --diarizer-worker` and accepts its socket
/// connection. The engine owns the listening socket for the whole run; each
/// worker incarnation connects to it, so a respawn does not churn the path.
public final class DiarWorkerProcessLauncher: DiarWorkerLaunching, @unchecked Sendable {
    private let socketPath: String
    private let cacheRoot: URL
    private let executableURL: URL
    private let logger: Logger
    private let listenLock = NSLock()
    private var listenFd: Int32 = -1

    public init(socketURL: URL, cacheRoot: URL,
                executableURL: URL = URL(fileURLWithPath: CommandLine.arguments[0]),
                logger: Logger = Logger(label: LogSubsystem.engine)) {
        self.socketPath = socketURL.path
        self.cacheRoot = cacheRoot
        self.executableURL = executableURL
        self.logger = logger
    }

    public func launch() async throws -> DiarWorkerHandle {
        try ensureListening()

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--diarizer-worker", "--diar-socket", socketPath,
                             "--cache-root", cacheRoot.path]
        let exited = ProcessExitGate()
        process.terminationHandler = { _ in Task { await exited.signal() } }
        try process.run()

        // accept() blocks until the worker connects (after it loads models).
        let connFd = try accept(timeout: .seconds(120))
        let connection = DiarWorkerConnection(fd: connFd)

        // First inbound frame must be the hello.
        var revision = ""
        for await body in connection.inboundBodies {
            if case let .hello(rev)? = try? DiarWorkerProtocol.decodeMessage(body) { revision = rev }
            break
        }

        return DiarWorkerHandle(
            connection: connection,
            modelRevision: revision,
            kill: { [weak process] in process?.terminate(); kill(process?.processIdentifier ?? -1, SIGKILL) },
            awaitExit: { await exited.wait() })
    }

    private func ensureListening() throws {
        listenLock.lock(); defer { listenLock.unlock() }
        guard listenFd < 0 else { return }
        unlink(socketPath)
        let fd = socket(AF_UNIX, sockStreamType, 0)
        guard fd >= 0 else { throw DiarWorkerLaunchError.socket(errno) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: 104) { strncpy($0, src, 103) }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else { close(fd); throw DiarWorkerLaunchError.bind(errno) }
        guard listen(fd, 1) == 0 else { close(fd); throw DiarWorkerLaunchError.listen(errno) }
        listenFd = fd
    }

    private func accept(timeout: Duration) throws -> Int32 {
        var pfd = pollfd(fd: listenFd, events: Int16(POLLIN), revents: 0)
        let ms = Int32(timeout.components.seconds * 1000)
        let rc = poll(&pfd, 1, ms)
        guard rc > 0 else { throw DiarWorkerLaunchError.acceptTimeout }
        let conn = Foundation.accept(listenFd, nil, nil)
        guard conn >= 0 else { throw DiarWorkerLaunchError.accept(errno) }
        return conn
    }

    deinit { if listenFd >= 0 { close(listenFd); unlink(socketPath) } }
}

public enum DiarWorkerLaunchError: Error, Equatable {
    case socket(Int32), bind(Int32), listen(Int32), accept(Int32), acceptTimeout
}

/// One-shot async gate for process exit (mirrors RecordOrchestrator.ProcessExitWaiter).
actor ProcessExitGate {
    private var exited = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() { exited = true; for w in waiters { w.resume() }; waiters.removeAll() }
    func wait() async {
        if exited { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
```

- [ ] **Step 4: Worker entry point in `main.swift`**

In `Sources/pulsartrace-engine/main.swift`, in the top-level branch (where `--live` is handled, ~line 24), add a `--diarizer-worker` branch **before** `--live`:

```swift
        if args.contains("--diarizer-worker") {
            await diarizerWorker(args: args, lifecycle: lifecycle)
            await lifecycle.stop()
            exit(0)
        }
```

Add the function (near `live(...)`):

```swift
    /// Worker mode (D43): connect to the engine's diarizer socket, load the
    /// FluidAudio diarizer, and serve windows until the connection closes or the
    /// engine SIGKILLs us. Stateless — holds no cross-window state.
    static func diarizerWorker(args: [String], lifecycle: AppLifecycle) async {
        guard let socketPath = value(after: "--diar-socket", in: args),
              let cacheRootPath = value(after: "--cache-root", in: args) else {
            FileHandle.standardError.write(Data("diar worker: missing --diar-socket/--cache-root\n".utf8))
            return
        }
        let cacheRoot = URL(fileURLWithPath: cacheRootPath)
        let engine: DiarizerEngine
        do {
            engine = try await DiarizerEngine.load(cacheRoot: cacheRoot, events: nil)
        } catch {
            FileHandle.standardError.write(Data("diar worker: model load failed: \(error)\n".utf8))
            return
        }
        // Connect to the engine (it is already listening + accepting).
        let fd = socket(AF_UNIX, sockStreamType, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: 104) { strncpy($0, src, 103) }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard rc == 0 else {
            FileHandle.standardError.write(Data("diar worker: connect failed: \(errno)\n".utf8))
            return
        }
        let connection = DiarWorkerConnection(fd: fd)
        let server = DiarWorkerServer(connection: connection,
                                      rawDiarizer: DiarizerEngineRawAdapter(engine: engine))
        await server.run()
    }
```

Add `#if canImport(Glibc) import Glibc #else import Darwin #endif` at the top of `main.swift` if not already present.

- [ ] **Step 5: Build**

Run: `swift build`
Expected: still FAILS only in `StreamingPipeline.swift` / `live()` wiring (replaced in Task 9). The new files compile. If other errors appear, fix them.

- [ ] **Step 6: Commit**

```bash
git add Sources/PulsarTraceEngine/Diarization/DiarWorkerProcessLauncher.swift Sources/pulsartrace-engine/main.swift
git commit -m "feat(diar): real process launcher + --diarizer-worker mode (D43)"
```

---

## Task 9: Wire the live path to the worker

Replace the in-process live diarizer with the worker client in `StreamingPipeline` + `live()`.

**Files:**
- Modify: `Sources/PulsarTraceEngine/Streaming/StreamingPipeline.swift`
- Modify: `Sources/pulsartrace-engine/main.swift` (the `live()` function)

- [ ] **Step 1: Change the pipeline Configuration + construction**

In `Sources/PulsarTraceEngine/Streaming/StreamingPipeline.swift`:

Replace the config field:
```swift
        public let liveDiarizerEngine: DiarizerEngine?
```
with:
```swift
        public let liveRawDiarizer: (any RawWindowDiarizing)?
```
(and the corresponding `init` parameter `liveRawDiarizer: (any RawWindowDiarizing)? = nil`, replacing `liveDiarizerEngine`).

Replace the `LiveDiarizer` construction (~`:144-147`):
```swift
        var liveDiarizer: LiveDiarizer?
        if let raw = configuration.liveRawDiarizer {
            liveDiarizer = LiveDiarizer(rawDiarizer: raw, logger: logger)
        }
```

- [ ] **Step 2: Spawn + wire in `live()`**

In `Sources/pulsartrace-engine/main.swift` `live(...)`, replace the in-process diarizer load (`~:168-182`, the `DiarizerEngine.load(...)` block assigned to `diarizerEngine`) with the worker client:

```swift
        // Live diarization runs in a separate killable worker process (D43): a
        // hung ANE prediction is recovered by SIGKILL, not a permanent in-process
        // leak. Best-effort — a launch failure degrades the live pass to generic
        // "Them" labels, same as before.
        var diarClient: DiarWorkerClient?
        if let recordingId = value(after: "--recording-id", in: args) {
            let socketURL = lifecycle.paths.diarizerSocketURL(recordingId: recordingId)
            let launcher = DiarWorkerProcessLauncher(
                socketURL: socketURL,
                cacheRoot: lifecycle.paths.modelsCacheDirectory)
            let client = DiarWorkerClient(launcher: launcher)
            await client.start()
            diarClient = client
        }
```

Replace the `Configuration(... liveDiarizerEngine: diarizerEngine ...)` argument with `liveRawDiarizer: diarClient`.

After `pipeline.run(...)` returns (end of `live()`), tear the worker down:
```swift
        if let diarClient { await diarClient.shutdown() }
```

(If `live()` has no `--recording-id` arg today, derive the id the same way the socket paths are derived for capture — reuse whatever `live()` already uses to build `systemSocketURL`. Use that identifier for `diarizerSocketURL`. Grep `live(` for `recordingId` / `systemSocketURL` and match it.)

- [ ] **Step 3: Build the whole package**

Run: `swift build`
Expected: PASS (clean build).

- [ ] **Step 4: Run the affected suites**

Run each, bare, `dangerouslyDisableSandbox: true`:
- `swift test --filter DiarWorker`
- `swift test --filter LiveDiarizerStitch`
- `swift test --filter LiveRunner`
- `swift test --filter Streaming`
- `swift test --filter UnitTests`

Expected: all PASS (or pre-existing explicitly-gated skips only). If `LiveRunner`/`Streaming` reference the removed `liveDiarizerEngine`/`LiveDiarizer(engine:)`, fix those call sites to the new API (they should already be covered, but a fixture/test helper may need updating).

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/Streaming/StreamingPipeline.swift Sources/pulsartrace-engine/main.swift
git commit -m "feat(diar): run live diarization in the worker process via DiarWorkerClient (D43)"
```

---

## Task 10: Integration test against the real worker binary (gated)

Proves the real `Process` spawn + socket accept + `hello` + one round-trip + kill/restart work end-to-end. Gated so it only runs when the diarizer models are present (it loads real CoreML).

**Files:**
- Create: `Tests/PipelineTests/DiarWorkerIntegrationTests.swift`

- [ ] **Step 1: Write the integration test**

```swift
import Testing
import Foundation
@testable import PulsarTraceEngine

/// End-to-end: spawn the REAL `pulsartrace-engine --diarizer-worker`, diarize a
/// window of silence, and confirm a result comes back. Gated on the built
/// engine binary + diarizer model cache being present (loads real CoreML).
@Suite("DiarWorker integration (real worker process)", .serialized)
struct DiarWorkerIntegrationTests {
    private var enginePath: URL? {
        // .build/debug/pulsartrace-engine relative to the package root.
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let p = cwd.appendingPathComponent(".build/debug/pulsartrace-engine")
        return FileManager.default.fileExists(atPath: p.path) ? p : nil
    }
    private var modelsReady: Bool {
        let dir = AppPaths.standard.modelsCacheDirectory.appendingPathComponent("speaker-diarization")
        return FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("Embedding.mlmodelc").path)
    }

    @Test("real worker returns a result for a window of audio",
          .enabled(if: ProcessInfo.processInfo.environment["PT_DIAR_WORKER_E2E"] == "1"))
    func realWorkerRoundTrip() async throws {
        guard let enginePath, modelsReady else { return }
        let socketURL = AppPaths.standard.diarizerSocketURL(recordingId: "itest-\(UUID().uuidString.prefix(8))")
        let launcher = DiarWorkerProcessLauncher(
            socketURL: socketURL,
            cacheRoot: AppPaths.standard.modelsCacheDirectory,
            executableURL: enginePath)
        let client = DiarWorkerClient(launcher: launcher, deadline: .seconds(20))
        await client.start()
        #expect(await client.modelRevision().isEmpty == false)
        // 10 s of silence at 16 kHz → a valid (likely empty) result, not nil.
        let window = [Float](repeating: 0, count: 16_000 * 10)
        let result = await client.diarizeRawWindow(samples: window)
        #expect(result != nil)
        await client.shutdown()
    }
}
```

- [ ] **Step 2: Build + run gated**

Run: `swift build`
Then, to actually exercise it, run with the env gate (bare is impossible with an env var prefix, so this one step is the documented exception — set the var in the shell when running manually):

`PT_DIAR_WORKER_E2E=1 swift test --filter DiarWorkerIntegration` (run manually; `dangerouslyDisableSandbox: true`).

Expected: PASS when models are present; **skipped** otherwise (default CI / normal dev runs — the test is `.enabled(if:)` on the env var, so the suite stays green without it).

- [ ] **Step 3: Commit**

```bash
git add Tests/PipelineTests/DiarWorkerIntegrationTests.swift
git commit -m "test(diar): gated end-to-end test of the real diarizer worker (D43)"
```

---

## Task 11: Manual verification on a real recording

Not an automated step — the acceptance check that the production symptom is gone.

- [ ] **Step 1: Build the dev binary**

Run: `swift build` (the menu-bar/dev app must launch this `.build/debug/pulsartrace-engine`).

- [ ] **Step 2: Record / replay the known-bad audio**

Replay the `2026-06-18-084407` morning recording (the one that wedges ~t=110s–210s) through a live session, ~7 min.

- [ ] **Step 3: Inspect the log**

```bash
grep -E "diar worker: restarting|RECLAIMED|SKIPPED|live trace diar:" ~/Library/Logs/PulsarTrace/<YYYY-MM-DD>.log
```

**Pass criteria:**
- `live trace diar:` lines keep appearing through the whole recording with `keys` > 1 (diarization is alive and tracking multiple speakers, not frozen).
- On a wedge, you see `diar worker: restarting (deadline)` followed within ~1–2 s by resumed `live trace diar:` lines — recovery, not a `SKIPPED`/`RECLAIMED` cascade.
- **Transcription never stalls:** `live trace transcriber[system]` keeps committing (`committedTokens` keeps growing) and `qSys`/`qMic` stay near 0 — the worker's wedges no longer starve Parakeet. No long "recording paused" stretch in `live.md`.

- [ ] **Step 4: Note the result** in `docs/specs/2026-06-18-live-pass-lag-investigation.md` (append a short "D43 verification" line with the observed behaviour).

---

## Cleanup note (after verification)

Once D43 is verified, the D42 in-process `DiarGate` reclaim is now a redundant backstop (the worker deadline + kill is the real mechanism, and the worker can no longer wedge the engine process). **Leave `DiarGate` as-is** — it still enforces the ≤1-window-in-flight bound and is harmless; do not remove it in this plan. A separate follow-up may simplify it.

---

## Self-Review

- **Spec coverage:** worker process (Tasks 8–9), audio over socket (Tasks 3, 5, 9), spans back (Tasks 2, 6), per-window deadline (Task 7), kill+respawn on hang (Task 7, 8), no cross-process ANE coordination (excluded — not implemented anywhere), `SIGKILL` releases the leak (Task 8 `kill` closure → `SIGKILL`; verified Task 11). Stitch state stays engine-side so restart loses no identity (Task 4). ✓
- **Placeholder scan:** every code step has complete code; commands have expected output; no "TBD"/"handle errors"/"similar to". ✓
- **Type consistency:** `RawWindowDiarizing.diarizeRawWindow(samples:)`/`modelRevision()` used identically in Tasks 4/6/7/8; `DiarWindowResult(.Span/.Embedding)` fields (`startMillis`/`endMillis`/`vector`) consistent across DTO (Task 2), stitch (Task 4), adapter (Task 8), tests; `DiarWorkerMessage.hello/.result(requestId:window:)` consistent (Tasks 2/6/7); `DiarWorkerHandle(connection:modelRevision:kill:awaitExit:)` consistent (Tasks 7/8); `Duration.milliseconds` defined once (Task 8 resolves the Task 7 duplicate). ✓
- **Known risk flagged:** `Duration.milliseconds` duplicate between Task 7 and Task 8 — Task 8 Step 1 explicitly resolves it (delete the private copy). The continuation-not-in-a-task-group pattern (Task 7) is called out specifically to avoid reintroducing the reaping hang.
