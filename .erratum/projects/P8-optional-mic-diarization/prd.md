# PT-P8 · Optional Microphone-Channel Diarization — Project PRD

**Status:** Open · **Opened:** 2026-07-29

## Scope

Today the microphone stream is structurally exempt from diarization: every mic utterance is
attributed to the canonical local speaker `You` (PT-R17), and only the system stream is clustered
into speakers. That model breaks for in-person meetings, where two or more people share the user's
microphone — their speech is silently merged into `You`. This project makes mic-channel diarization
a **per-recording, opt-in** capability applied in the refine pass: the default behavior is exactly
today's (`You`, never diarized), a recording can be marked for mic diarization when it starts or —
critically — at any time after it was recorded, and un-marking it and re-refining restores the
single-`You` transcript. The live pass is deliberately untouched: `live.md` continues to label all mic speech
`You`; the split appears in `final.md` where refinement already re-reads the persisted
`audio-mic.wav`.

`You` remains a canonical concept. To keep it canonical when the mic carries several voices, the
engine maintains an **owner voice profile**: a persistent voiceprint centroid in the unified
speaker-embedding space (PT-R112), learned passively from the mic stream of ordinary,
non-mic-diarized recordings (which is by construction almost entirely the user's voice). In a
mic-diarized refine, the cluster matching the owner profile is labeled `You`; every other mic
cluster flows through the existing reconciler (PT-R22/PT-R23) and becomes an ordinary speaker
library entry — placeholder-named, renameable, mergeable, and recognized across meetings and across
channels (a colleague who appears on the system stream in remote meetings and on the mic in
in-person ones reconciles to the same library speaker, because live, offline, and library embeddings
already share one space). Attribution is fail-safe: with no profile or no confident match, no
cluster is silently labeled `You`; the speaker editor gains an explicit owner-reassignment action
("this is me") to correct or bootstrap.

Because refinement is already a re-runnable post-hoc pass over persisted WAVs, the machinery reuses
what exists: the diarizer (PT-C3) gains a mic-stream entry point, the refinement pipeline (PT-C4)
a conditional mic-diarization stage, the speaker library (PT-C5) an owner-profile store beside —
never inside — the speaker table, and the merge/metadata tail per-cluster mic labels. The
per-recording option is an input, so it lives in a new `options.json` sidecar in the recording
folder (UI/CLI-owned input, like `title.txt`), not in `metadata.json`, which is a refinement
output. Surfaces follow: a non-sticky record-time toggle and a per-recording action in the app
(PT-C16), a `pulsartrace refine` flag (PT-C9), the MCP refine tool (PT-C22), additive `metadata.json`
fields (PT-C11), and events (PT-C6). Along the way the project closes KI-3 by identifying the
owner/mic speaker structurally instead of by the mutable display name `"You"` in the Speaker Edit
Service (PT-C23).

Deliberately out of scope: live-pass mic diarization (the per-recording option and the owner
profile are designed so a later project can add it without rework), explicit voice-enrollment UX
(passive learning plus "this is me" covers bootstrap), and any change to echo dedup (PT-R19), which
continues to apply unchanged before mic attribution.

## Project Requirements

Each requirement carries a **type** (functional / technical / constraint) and a **change-type**
against the product layer (Introduce / Supersede(target) / Retire(target)). These are mutable drafts
until close-out.

### PT-P8-R1 · Functional · Supersede(PT-R17) — Microphone diarization is per-recording opt-in

By default, microphone-origin speech is attributed to the local speaker `You` and is never sent to
diarization — exactly the behavior PT-R17 mandates today. When a recording's mic-diarization option
is enabled, the refine pass additionally diarizes the microphone stream and attributes mic speech
per cluster (PT-P8-R4, PT-P8-R5). The live pass never diarizes the microphone stream regardless of
the option; `live.md` labels all mic speech `You`.

*Supersedes:* PT-R17 (mic never diarized) with "mic diarized only on per-recording opt-in, in the
refine pass". *Acceptance:* a recording refined with the option off yields a `final.md`/
`metadata.json` byte-equivalent (modulo timestamps) to today's output; the same recording refined
with the option on yields per-cluster mic attribution; `live.md` is identical in both cases.

### PT-P8-R2 · Functional · Introduce — Per-recording options sidecar

The mic-diarization option is a per-recording **input** persisted as an `options.json` sidecar in
the recording folder — written by the app, CLI, or MCP surface; read by every refine pass; absent
means all-defaults (mic diarization off). Toggling the option and re-refining converges the
recording's outputs to the option's state: disabling it restores the single-`You` transcript from
the persisted WAVs. `metadata.json` remains a pure refinement output.

*Acceptance:* enable → refine → disable → refine round-trips to single-`You` output; a missing or
malformed sidecar refines with defaults and does not fail the pass.

### PT-P8-R3 · Technical · Introduce — Owner voice profile

The engine maintains a persistent owner voice profile: a centroid in the unified speaker-embedding
space (PT-R112), pinned to the diarization model revision with the same archive-and-reset migration
semantics as the speaker library (PT-R113). It is stored alongside the speaker library but is not a
library speaker — it can never be listed, renamed, merged, delisted, or matched by the reconciler.
It is updated by running mean from three sources: (a) passively, during refinement of
non-mic-diarized recordings, from mic-stream speech that survived echo dedup, gated by an inlier
check so a borrowed microphone does not poison the profile; (b) from the `You`-attributed cluster of
a mic-diarized refine; (c) from explicit owner designation (PT-P8-R6). With no profile present,
passes proceed; only automatic `You` attribution (PT-P8-R4) is unavailable.

*Acceptance:* profile is created/updated across refines of ordinary recordings; an embedding far
from the existing profile is rejected by the inlier gate; a model-revision change archives and
resets the profile without failing refinement.

### PT-P8-R4 · Functional · Introduce — Fail-safe `You` attribution among mic clusters

In a mic-diarized refine, the mic cluster whose embedding best matches the owner profile at or above
the calibrated match threshold is labeled `You`. At most one cluster is `You`. If no owner profile
exists, or no cluster reaches the threshold, **no cluster is auto-labeled `You`** — all mic clusters
take the guest path (PT-P8-R5) and the user can designate the owner explicitly (PT-P8-R6). `You` is
never assigned by guesswork (e.g. dominant-speaker heuristics).

*Acceptance:* on a two-speaker mic fixture with a seeded owner profile, the owner's cluster is
labeled `You` and the other is not; with no profile, neither is `You` and both surface as library
speakers.

### PT-P8-R5 · Functional · Introduce — Mic guests are ordinary library speakers

Non-owner mic clusters are reconciled against the speaker library exactly as system-stream clusters
are (PT-R22/PT-R23): matched speakers take their library names and refine their centroids; unmatched
clusters mint `Unknown #N` placeholders. Mic-channel speakers get the full speaker-edit surface
(rename, merge, split, delist, undelist) and are recognized across meetings and across channels —
the same person reconciles to one library speaker whether they arrived via mic or system stream.

*Acceptance:* a guest speaker recorded on the mic in one recording and on the system stream in
another reconciles to the same `spk_` id; speaker-edit operations on a mic-channel speaker rewrite
`final.md` and emit events identically to system-channel speakers.

### PT-P8-R6 · Functional · Introduce — Explicit owner reassignment

The speaker editor supports designating, per recording, a mic-channel speaker as the owner ("this is
me"): the recording's lines for that speaker re-attribute to `You` via the retroactive `final.md`
rewrite, the owner profile updates from that cluster's embedding, and a library speaker minted
solely from that misattribution is removed. The inverse ("not me") demotes a recording's `You`
mic-channel attribution to an ordinary library speaker. Both emit paired cause + `final_md_rewritten`
events in causal order.

*Acceptance:* designation and demotion each round-trip on a mic-diarized recording, with correct
`final.md`, `metadata.json`, library, and event outcomes.

### PT-P8-R7 · Functional · Introduce — Structural owner identity (closes KI-3)

The owner/mic speaker is identified by a structural marker — never by comparing the mutable display
name to `"You"` — across edit guards, outputs, and surfaces. The label `You` is reserved: the
reconciler and the speaker-edit surface never let a library speaker carry it, and the owner
speaker's transcript label is fixed. The delist guard keys on the structural marker, closing KI-3
(renaming can no longer make the mic speaker delistable, and a guest named `You` is impossible).

*Acceptance:* the KI-3 scenarios (rename mic speaker then delist; name a guest `You`) are rejected
or impossible; KI-3 is removed from the known-issues register at close-out.

### PT-P8-R8 · Functional · Introduce — Record-time and post-hoc selection in the app

The record surface gains a non-sticky, default-off per-recording toggle ("in-person meeting —
diarize my microphone") that writes the options sidecar at recording start so auto-refine honors
it. The recordings pane gains a per-recording action to enable or disable mic diarization for an
existing recording, persisting the option and enqueueing a re-refine through the existing job queue
(PT-C17). Recording rows and the detail pane surface mic-channel guests with the same pills and
editor affordances as system speakers.

*Acceptance:* toggle set at record → auto-refine produces mic-diarized output; per-recording action
on a past recording produces it post-hoc; disabling + re-refine restores single-`You`; the toggle
resets to off for the next recording.

### PT-P8-R9 · Functional · Introduce — CLI and MCP surfaces

`pulsartrace refine` accepts an explicit mic-diarization override that persists the option to the
recording's sidecar before refining (so subsequent refines agree), and the MCP surface exposes the
same capability on its refine tool plus the recording's mic-diarization state in its metadata
responses.

*Acceptance:* CLI flag round-trips the sidecar and output; MCP refine tool accepts the option and
recording queries reflect it.

### PT-P8-R10 · Technical · Introduce — Output-contract evolution

`metadata.json` reports mic diarization additively: a field recording whether the pass diarized the
mic stream, and per-speaker `is_microphone` loosened to mean "attributed to the microphone stream"
(so several speakers may carry it; `You` keeps `speaker_id: null`, mic guests carry their `spk_`
ids). Changes follow the sidecar's existing SemVer rule (additive fields are non-breaking). New
owner-profile and owner-reassignment events join the events log in causal order and respect the
non-content rule (PT-R84).

*Acceptance:* pre-P8 consumers of `metadata.json` parse post-P8 files unchanged; events for a
mic-diarized refine and an owner reassignment appear in documented causal order with no
content/path leakage.

### PT-P8-R11 · Constraint · Introduce — Echo dedup precedes mic attribution

Enabling mic diarization must not weaken microphone-echo dedup (PT-R19): mic utterances that
duplicate system-stream speech are dropped before mic clusters are attributed, so hybrid meetings
(remote participants on the system stream, several people in the room) do not attribute
system-audio bleed-through to a mic speaker.

*Acceptance:* on a paired mic+system fixture with overlapping speech, dedup behavior with the option
on matches behavior with it off.
