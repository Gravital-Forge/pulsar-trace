# PT-P8 · Optional Microphone-Channel Diarization — Decision Log

The reasoning behind this project's choices, recorded as each was taken.

## Decisions

### PT-P8-D1 · Post-hoc only: the live pass stays untouched

*2026-07-29*

**Decision:** Mic diarization runs only in the refine pass. `live.md` continues to label every mic
utterance `You`, option or no option.

**Because:** The stated need — "possible to apply after the meeting was recorded" — is inherently a
refinement capability, and refinement already re-reads the persisted `audio-mic.wav`, so post-hoc
application and revert-by-re-refine come nearly free. Live mic diarization would touch the streaming
pipeline, the provisional label space, and live echo-dedup interplay for a much larger blast radius.
The per-recording option and the owner profile are channel-agnostic, so a later project can add a
live mode without rework. Alternative (live + post-hoc in one project) rejected as scope creep.

### PT-P8-D2 · Owner voice profile with passive learning, not manual pick or enrollment

*2026-07-29*

**Decision:** `You` is identified among mic clusters by matching against a persistent owner
voiceprint (a centroid in the unified embedding space), learned passively from the mic stream of
ordinary non-mic-diarized recordings (inlier-gated), and corrected/bootstrapped by an explicit
"this is me" action.

**Because:** Almost every recording the user ever makes is a labeled sample of their own voice —
the mic stream of a normal meeting is the user by construction — so the profile builds itself with
no UX. Alternatives: manual per-meeting cluster pick (rejected as primary: recurring friction, and
`You` would stop being automatic — kept as the correction/bootstrap path); dominant-speaker
heuristic (rejected outright: silently mislabeling someone else as `You` is the worst failure mode
for a canonical concept); explicit enrollment flow ("record 30 s of your voice" — rejected for now:
adds UX surface passive learning makes unnecessary; can be added later if passive proves noisy).

### PT-P8-D3 · Fail-safe attribution: no confident match means no `You`

*2026-07-29*

**Decision:** If no owner profile exists or no mic cluster reaches the match threshold, no cluster
is auto-labeled `You`; all mic clusters take the ordinary library path and the user designates the
owner explicitly.

**Because:** A transcript with an unlabeled owner is a visible, one-click-fixable gap; a transcript
with the wrong `You` is a silent lie that also poisons the owner profile via the running-mean
update. Wrong-`You` is strictly worse than no-`You`.

### PT-P8-D4 · Mic guests join the one shared speaker library

*2026-07-29*

**Decision:** Non-owner mic clusters reconcile against the same speaker library as system-stream
clusters, with the same placeholder naming, centroid updates, and edit surface.

**Because:** PT-R112 already guarantees live, offline, and library embeddings share one space, so a
person's voice reconciles identically regardless of arrival channel — a separate mic-speaker
namespace would split one human into two library identities the moment they attend both an
in-person and a remote meeting. The prior "mic speakers are never in the library" rule was a
corollary of PT-R17, not an independent invariant; superseding one supersedes both.

### PT-P8-D5 · The option is an input-side `options.json` sidecar

*2026-07-29*

**Decision:** The per-recording flag persists in a new `options.json` sidecar in the recording
folder, written by UI/CLI/MCP and read by every refine pass. `metadata.json` is untouched as an
input channel.

**Because:** `metadata.json` is a pure refinement *output*, regenerated every pass — round-tripping
an input through it muddies the public contract and breaks for never-refined recordings. A
queue-job-only flag would be forgotten on the next re-refine, violating "toggling converges the
outputs". A global setting contradicts the explicit constraint that not all meetings be diarized.
The sidecar follows the `title.txt` precedent of UI-owned per-recording files the engine reads.

### PT-P8-D6 · Record-time toggle is per-recording, non-sticky, default off

*2026-07-29*

**Decision:** The record-surface toggle applies to the recording being started, then resets to off.

**Because:** The user's framing — `You` stays canonical, "we don't want to diarize all meetings" —
makes opt-in-per-meeting the contract; a sticky toggle silently converts one in-person meeting into
a standing mode. The post-hoc action (enable later + re-refine) keeps the cost of forgetting the
toggle at zero.

### PT-P8-D7 · Close KI-3 (structural owner identity) in this project

*2026-07-29*

**Decision:** Replace the display-name-keyed mic-speaker guard with a structural marker, reserve
the label `You`, and remove KI-3 at close-out.

**Because:** This project rewrites the exact guard KI-3 lives in (the Speaker Edit Service's
`"You"` comparison) and multiplies the cost of leaving it: with mic guests in the library, a guest
named `You` would collide with fail-safe attribution, not just delisting. Fixing it here is cheaper
than working around it and fixing it later.

### PT-P8-D8 · Revert is re-refine, not bespoke undo

*2026-07-29*

**Decision:** Disabling mic diarization on a recording and re-refining is the undo mechanism; no
dedicated inverse-rewrite machinery is built.

**Because:** Refinement is already deterministic re-generation from persisted WAVs plus the sidecar
inputs — the single-`You` transcript is exactly what a refine with the option off produces. A
bespoke undo would duplicate that guarantee and add a second code path that can drift from it.
