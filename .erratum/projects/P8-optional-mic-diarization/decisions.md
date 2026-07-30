# PT-P8 · Optional Microphone-Channel Diarization — Decision Log

The choices behind the opt-in mic-diarization mode — where the option lives, how `You` stays
canonical via the owner voice profile, and what the mode covers — recorded as each was taken.

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

### PT-P8-D9 · The mode covers the live pass too (supersedes PT-P8-D1)

*2026-07-29*

**Decision:** With a recording's mic-diarization stamp on, the live pass windows-diarizes the mic
stream and shows provisional labels in `live.md`, exactly as it does for the system stream; the
refine pass finalizes. PT-P8-D1's refine-only scoping is superseded.

**Because:** User direction on design review: refine-only mic diarization makes the feature behave
differently from every other diarization the app does — the system channel shows provisional
speakers live and firms them up at refine, and a mic channel that flips from all-`You` to
multi-speaker only at refine is a visible discontinuity and a harder mental model. UX parity wins:
"you toggle it, you start your meeting, and that's it." The costs D1 avoided are bounded: the extra
windowed diarizer runs on the ANE only when the mode is on (default off), diarization windows are
light relative to Parakeet transcription (relevant after the thermal-wedge history), and the
post-hoc apply/revert capability is unchanged — it never depended on refine-only scoping, only on
refines re-reading the persisted WAVs.

### PT-P8-D10 · Sticky global toggle stamps recordings; refines follow the stamp (supersedes PT-P8-D6)

*2026-07-29*

**Decision:** The mode switch is a persisted, default-off Settings toggle (the `systemAudioEnabled`
precedent), whose value is stamped onto each recording at record start. Every refine follows the
recording's own stamp; the per-recording control in the recordings pane edits the stamp (flip +
Refine = post-hoc apply/revert). Manual refine never silently consults the ambient global toggle.
PT-P8-D6's non-sticky record-time toggle is superseded.

**Because:** User direction: the control should feel like an app mode ("a toggle you press in the
settings"), not a per-recording ritual — someone in a stretch of in-person meetings flips it once.
Stamping at start keeps recordings self-describing and refines deterministic. The alternative the
review floated — refine reads the current global toggle at click time — was rejected for its
retroactivity: re-refining an old in-person recording months later (say, after a model upgrade)
with the toggle since turned off would silently collapse its speakers back to `You`; with the
stamp, a recording's transcript shape changes only when the user edits that recording's own state.
PT-P8-D5 is unaffected: the sidecar remains the per-recording input home, and what D5 rejected — a
global setting *instead of* per-recording state, where every meeting diarizes alike — is still
rejected; the toggle only chooses the default each new recording is stamped with.

### PT-P8-D11 · `Guest` is the live provisional label family for mic clusters

*2026-07-29*

**Decision:** Unmatched mic clusters in the live pass take `Guest`, `Guest #2`, … provisional
labels with the existing `?` pre-reconciliation semantics, alongside `You` (owner match) and
library names (read-only match).

**Because:** The system stream already owns the `Them` family; reusing it for mic clusters would
make a hybrid meeting's transcript ambiguous about who was in the room versus on the call, which is
exactly the distinction an in-person mode exists to capture. A distinct family also keeps the two
streams' provisional label spaces independent, matching the no-cross-stream-stitching scope
boundary. Naming stays provisional-only: refine replaces the family with reconciled names.

### PT-P8-D12 · Owner-profile backfill on first enable

*2026-07-29*

**Decision:** When the global toggle is first enabled and no owner profile exists, a one-shot
backfill builds it from the mic WAVs of recent existing recordings before passive learning takes
over.

**Because:** With live `You` attribution now in scope (PT-P8-D9), a cold profile would make the
mode's first outing label the user's own speech `Guest ?` live — the worst first impression the
feature could make, and entirely avoidable for established users whose disk already holds hours of
single-voice mic audio. Fresh installs with no recordings still degrade gracefully (provisional
labels until refine plus "this is me" seeds the profile); an explicit enrollment flow remains
unnecessary (PT-P8-D2).

### PT-P8-D13 · Extend echo dedup to the refine pass; supersede PT-R19's inverted wording

*2026-07-29*

**Decision:** The refine pass gains mic-echo dedup ahead of mic attribution and owner-profile
learning, applied whether or not the recording's mic-diarization stamp is on. PT-P8-R11 changes
from a Constraint on existing behavior to a Functional Supersede(PT-R19) that states the drop
direction correctly (mic-side duplicates dropped; system stream authoritative).

**Because:** Design-record verification against the codebase found the PRD's premise wrong: echo
dedup exists only in the live pass (`MicEchoDedup` in the streaming layer), while the refine pass
appends every mic segment unconditionally — and the PRD simultaneously forbade dedup changes in its
out-of-scope list while resting owner-profile purity on refine-side dedup ("speech that survived
echo dedup"). The gap is load-bearing for this feature: without refine-side dedup, speaker-audio
bleed-through in hybrid meetings duplicates remote speech in `final.md`, mints or contaminates mic
guest clusters, and poisons passive profile learning. Alternatives rejected: constraining the dedup
story to the live pass and defending the profile with the inlier gate alone (duplicated `final.md`
lines and phantom guests would undermine the feature's core promise exactly in the hybrid case it
exists for); introducing a separate refine-side requirement while leaving PT-R19 untouched (PT-R19's
body states the inverse drop direction from what the code does — carrying a knowingly-wrong product
requirement past the project that touches exactly this behavior contradicts how this product
handles drift; supersession at close-out is the correct repair). Dedup applies mode-on or off
because the duplication bug is real either way — a mode-off refine that re-admits echo the live
pass dropped is wrong today, not just wrong for P8.
