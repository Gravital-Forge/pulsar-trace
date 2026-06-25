# PT-P5-E1 · ANE Transcription Pipeline — Completion Record

**Status:** Frozen · **Closed:** 2026-06-13

## What was built

Both transcription passes now run on the Apple Neural Engine, in-process, and whisper.cpp is gone.

The live pass runs **Parakeet TDT 0.6B v3** through FluidAudio: a resident `ParakeetEngine` (loaded
once, shared by both streams, with a script-aware `languageHint`), a `ParakeetWindowTranscriber`
conforming to the existing `WindowTranscribing` seam, and a `ParakeetTokenMapper` turning
SentencePiece token timings into per-word segments. The live pass has no model knob anywhere — no
engine `--model`, no settings entry — and `recording_started.model_live` is fixed to `parakeet-v3`.
A live window is bounded by a 30 s semaphore deadline; an over-run window is skipped and recovered
by the post-pass.

The refine pass runs **WhisperKit** (argmax-oss-swift) over a fixed two-model catalog
(`WhisperKitModelCatalog`): `large-v3-turbo` (`…626MB`, default) and `large-v3` (`…947MB`, the
accuracy fallback), chosen in Settings or via `refine --model` / `record --refine-model`.
`FluidVADRegionDetector` produces Silero-CoreML speech regions with the same 800 ms coalescing;
`WhisperKitRegionTranscriber` decodes each region with a non-reentrant decode lock, a truthful
deadline, and a budgeted language detect; `WhisperKitLanguagePolicy` resolves pin / detect-among /
auto from the language allow-list and an explicit `--language` override; `WhisperKitSegmentMapper`
maps segments with the D31 hallucination gate ported onto WhisperKit's per-segment
`noSpeechProb`/`avgLogprob`. A wedged refine decode stops at a per-token callback boundary; pausing
for a recording cancels the in-flight decode, drops the WhisperKit actor (ARC frees the CoreML
models), and requeues the job to resume from its checkpoint.

Model bundles are SDK-managed directories under `~/Library/Caches/PulsarTrace/models/` with no
pinned SHA-256; `DirectoryDigest` computes a deterministic SHA-256 tree hash carried on
`model_downloaded`, and `RefinementJob.modelSHA256` / the `metadata.json` hash field record `""`.
The shared option/error types became `TranscriptionOptions`/`TranscriptionError` (whisper's
`threadCount`/`temperature`/ `vadModelURL` knobs and `AbortToken` removed).

whisper.cpp was removed wholesale: `CWhisper`, the vendored Metal build, the `pulsartrace-whisper`
subprocess, `WhisperIPC`, `WhisperTranscriber`, and `ModelStore`/`ModelCatalog`, followed by a
rename sweep across the CLI help text, comments, and docs.

## Deltas from the spec

None. Diarization deliberately stayed on Python/pyannote at the close of this epic; its ANE
migration is PT-P5-E2.

## Requirements satisfied

- **PT-P5-R1** (resident ANE transcription) —
  `Sources/PulsarTraceEngine/Transcription/Parakeet/ParakeetEngine.swift`,
  `ParakeetWindowTranscriber.swift`, `ParakeetTokenMapper.swift`;
  `Sources/PulsarTraceEngine/Transcription/WhisperKit/WhisperKitRegionTranscriber.swift`,
  `WhisperKitModelCatalog.swift`, `WhisperKitSegmentMapper.swift`, `WhisperKitLanguagePolicy.swift`;
  `Sources/PulsarTraceEngine/Transcription/FluidVADRegionDetector.swift`, `TranscriptTypes.swift`,
  `TranscriptionOptions.swift`.
- **PT-P5-R2** (SDK-managed model acquisition) — WhisperKit/FluidAudio SDK download into
  `AppPaths.modelsCacheDirectory`; the PulsarTrace `ModelStore` was removed.
- **PT-P5-R3** (content-digest model integrity) —
  `Sources/PulsarTraceEngine/Transcription/DirectoryDigest.swift`; `model_downloaded` payload.
- **PT-P5-R4** (in-process ANE-bounded decode recovery) — WhisperKit per-token deadline in
  `WhisperKitRegionTranscriber.swift`; the refine queue's in-process pause/cancel/requeue path
  (PT-C17); the 30 s live-window deadline in `ParakeetWindowTranscriber.swift`.
- **PT-P5-R5** (retire the out-of-process recognizer) — removal of `pulsartrace-whisper`,
  `WhisperIPC`, and `RemoteTranscriberCore`; the live drain and refine queue invoke the recognizer
  in-process.

## To flow into the product layer

At project close-out (when this branch merges to main), reconcile per `references/close-out.md`:

- **Mint** PT-R107 (resident ANE transcription — Parakeet live + WhisperKit refine), **superseding**
  PT-R9; PT-R108 (SDK-managed model acquisition), **superseding** PT-R54c; PT-R109 (content-digest
  model integrity / `DirectoryDigest`), **superseding** PT-R54d; PT-R110 (in-process ANE-bounded
  decode recovery), a fresh introduce.
- **Retire** PT-R97 (recording isolated from decode hangs via the out-of-process recognizer); its
  decode-hang-isolation guarantee is carried forward in-process by PT-R110.
- **Architecture:** rewrite PT-C2 (Transcription Engine) to the WhisperKit/Parakeet ANE backends;
  rewrite PT-C12 (Streaming Transcription) for the Parakeet window pass; update PT-C4/PT-C17 for the
  in-process decode cancel; mark PT-C10 (Model Store) and PT-C19 (Out-of-Process Recognizer)
  **Retired**; update PT-C18 (Recording Durability) to drop the offload to PT-C19. Add a new
  component for the content-digest model identity if close-out judges `DirectoryDigest` large enough
  to warrant one (otherwise fold it into PT-C2).
- **Traceability:** two-write supersession rows for R9→R107, R54c→R108, R54d→R109; a write-once row
  for R110; terminal Retired flip on R97.
- **Reference sweep:** grep for any lingering reference to PT-R9 / PT-R54c / PT-R54d / PT-R97 and to
  the retired components, and resolve each.
