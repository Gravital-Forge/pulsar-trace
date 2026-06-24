# PT-P3 · Resilience & Refinement Robustness — Decision Log

The choices behind durable recording, the refinement queue, and decode-hang isolation. Frozen at
project close.

## Decisions

### PT-P3-D1 · Crash-safe incremental WAV

*2026-05-18*

**Decision:** The live pass streams the recording WAV to disk frame-by-frame, re-patching the file
header as it grows, so the on-disk file is always valid; the in-RAM end-of-run dump is removed.

**Because:** A wedge-then-force-kill of an in-RAM buffer lost an entire recording; an incrementally
written file caps the loss at about a second.

### PT-P3-D2 · Capture stall detection and auto-restart

*2026-05-18*

**Decision:** Each capture engine runs a frame watchdog (a few seconds without audio) that rebuilds
just that engine with backoff retry, surfaced through the existing pause/resume frames; an
engine-side backstop tolerates daemon death.

**Because:** A silently stalled stream left the engine alive but wedged; reusing the pause/resume
mechanism recovers it without a new control path.

### PT-P3-D3 · Single-worker refinement job queue

*2026-05-19*

**Decision:** Refinement runs through a persisted, single-worker FIFO queue with per-region
checkpointing, so a recording stops and returns to idle immediately while its refine is enqueued;
the CLI keeps its direct one-shot refiner.

**Because:** A finished recording auto-triggering an in-line refine blocked the next meeting; a
queue decouples them and survives restarts.

### PT-P3-D4 · Queue UI polls a snapshot

*2026-05-19*

**Decision:** The refinement-queue view refreshes by polling a snapshot at a fixed short interval
rather than threading a push channel across the actor boundary.

**Because:** Polling matches the other live views and avoids a fragile cross-actor stream for a
low-frequency update.

### PT-P3-D5 · Reuse one recognizer per refinement job

*2026-05-20*

**Decision:** A refinement job builds one recognizer and reuses it across all regions, rather than
constructing one per region.

**Because:** Per-region construction re-initialized the GPU pipeline each time, costing many seconds
per region; reuse trades a larger resident footprint for far faster refines.

### PT-P3-D6 · Advisory lock on the event log

*2026-05-20*

**Decision:** Every event-log append takes an exclusive advisory file lock.

**Because:** The log is shared across the capture, menubar, and CLI processes, and an interleaved,
clobbered line was observed; the lock serializes cross-process appends.

### PT-P3-D7 · Live pass: recording-safe drain plus best-effort decode worker

*2026-05-22*

**Decision:** The live run splits into a recording-safe drain (WAV, diarization, and a bounded
drop-oldest queue, never calling the recognizer) and a best-effort decode worker (offloaded, with a
watchdog and abort token), so a hung decode cannot lose the recording.

**Because:** The recognizer is the only component that can wedge; isolating it behind a bounded
queue keeps the durable recording safe even when decoding stalls.

### PT-P3-D8 · Pause cancels and requeues the in-flight diarization

*2026-05-19*

**Decision:** Pausing the queue for a recording cancels the in-flight diarization subprocess and
requeues that region, accepting at most one short re-run per pause cycle.

**Because:** Capture needs the resources immediately; a cancelled-and-retried region is cheaper than
waiting for a long diarization to finish, and a cancelled diarize is treated as retryable, not a
failure.

### PT-P3-D9 · Move the recognizer out of process for kill-able recovery

*2026-05-26*

**Decision:** Transcription inference moves into a separate recognizer subprocess over IPC, so a
wedged decode can be force-killed and respawned from the parent; the in-process abort path proved
insufficient.

**Because:** A native decode can wedge below the level an in-process abort can interrupt; only a
separate process can be reliably killed and restarted without taking down the engine.
