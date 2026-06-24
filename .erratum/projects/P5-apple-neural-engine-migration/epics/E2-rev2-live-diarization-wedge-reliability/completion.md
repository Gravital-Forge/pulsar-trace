# PT-P5-E2-rev2 · Live-Diarization Wedge Reliability — Completion Record

**Status:** Open — interim record · **Last updated:** 2026-06-23

This epic is **open**: the work below is resolved on the `fix/live-diarizer-wedge-reclaim` branch
but is **not yet merged** into the integration branch (`feat/ane-transcription-pipeline`, tip
`8ae53bb`), so it is not part of the current shipped state. This record is interim and will be frozen
when the tail merges.

## What was built

The live-diarization wedge was chased through two dead ends before it was root-caused and fixed at
its real source; live diarization then stayed in-process.

**Attempt 1 — gate-reclaim (PT-P5-D6, `2992ca5`).** `DiarGate` gained a slot-reclaim: a slot held
past a 2 s deadline is force-reclaimed without awaiting the wedged work, with a generation token so a
late `release()` from the abandoned window cannot free a newer holder's slot. It stops a single
transient wedge but proved **insufficient** under a wedge storm — it relaunched a new window every 5 s
into a still-jammed pipeline, the (believed un-cancellable) calls accumulated one per ~5 s, and after
~6–7 they starved the Parakeet decodes and paused the recording. So it turned a diarization-only
freeze into a recording regression.

**Attempt 2 — killable worker subprocess (PT-P5-D7, `0d3b540`…`d28f760`).** Live diarization was moved
into its own killable worker process (the `--diarizer-worker` engine mode, `DiarWorkerClient`/
`Server`/`Connection`/`Protocol`/`Launcher`, a per-session Unix-domain socket, a 4-byte length-prefixed
wire codec, and a supervisor with a per-window deadline plus SIGKILL/respawn), so a "wedged ANE call"
could be released by killing the process. Cross-window stitch state stayed engine-side so a respawn
lost no speaker identity.

**Root cause + the real fix (PT-P5-D7).** An `lldb` + `spindump` capture of a stuck worker showed its
serving thread parked ~85 s inside `NSFileHandle.write → write` (CPU < 1 ms; the ANE idle), emitting
a `[Profiling]` line that itself reported the embedding had already succeeded in ~6 ms. The wedge was
never ANE contention: FluidAudio logs verbosely to stderr, the worker inherited the engine's stderr,
and the engine drained that pipe **byte-by-byte** on the cooperative pool — so under the DEBUG flood
the 64 KB pipe filled and the next `write()` blocked forever. The fix is at the source: route the
subprocess stdio to `/dev/null` (`912208e`), and drain subprocess pipes in chunks via a background
`readToEnd()` in `RecordOrchestrator` instead of byte-by-byte `FileHandle.bytes` (`80faa21`).

**Revert to in-process (PT-P5-D7, `531a1cc`).** With the cause fixed at the drain, the worker was dead
weight and was reverted entirely (≈ −1180 lines), along with the PT-P5-D6 reclaim and generation
token. Live diarization runs in-process via `DiarizerEngineRawAdapter` over the resident
`DiarizerEngine` the live pass loads — the offline `Diarizer` keeps its own instance of the same type
and WeSpeaker model — and `DiarGate` is back to a plain
≤1-in-flight gate; the invariant "a wedged diarizer never stalls transcription or `live.md`" still
holds via the detached-task + single-slot structure (test `wedgedDiarizerDoesNotStallTranscription`).

**§2b label collapse (PT-P5-D8, `a662ebb`).** `LiveRunner.resolveSystemLabel` no longer falls back to
`"Them"` when the diarizer has no coverage for an utterance — `"Them"` is exactly
`LiveDiarizer.provisionalKey(index: 0)`, so the old fallback made a no-coverage line inherit the first
speaker's centroid and name. It now returns the neutral `LiveRunner.noCoverageLabel` (`Speaker?`) and
skips the R18 lookup, covered by no-coverage regression tests.

## Deltas from the spec

The first two approaches (gate-reclaim, worker subprocess) were investigative attempts that did not
ship; the worker subprocess and its components are **not** part of the current state. The shipped
resolution is the in-process revert plus the two pipe-drain fixes and the §2b label fix.

## Requirements satisfied

None new — this epic hardens existing live-pass behaviour (PT-R15/R16 live diarization; the
wedged-decode isolation intent carried by PT-P5-R4) and fixes a labelling bug. The work is recorded in
decisions PT-P5-D6, PT-P5-D7, and PT-P5-D8.

Relevant current-branch files the in-process design uses: `Sources/PulsarTraceEngine/Streaming/`
(`LiveDiarizer.swift`, `DiarGate.swift`, `DiarState.swift`, `LiveRunner.swift`),
`Sources/PulsarTraceEngine/Diarization/DiarizerEngine.swift`, and
`Sources/PulsarTraceEngine/Engine/RecordOrchestrator.swift` (the chunked pipe drain).

## To flow into the product layer

- No requirement to mint, supersede, or retire. At close-out, confirm the live-diarization and
  record-orchestrator component descriptions (PT-C13, and PT-C9 / the orchestrator's subprocess-drain
  note) reflect the in-process design and the chunked drain, and that the live no-coverage `Speaker?`
  marker is reflected wherever the provisional live-label markers are described (transcript-format
  contract).
- **Open before this epic can close:** merge the `fix/live-diarizer-wedge-reclaim` tail into the
  integration branch so the resolution (worker revert, the two pipe-drain fixes, the §2b label fix) is
  part of the shipped state, then freeze this record.
