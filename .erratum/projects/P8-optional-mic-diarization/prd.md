# PT-P8 · Optional Microphone-Channel Diarization — Project PRD

**Status:** Frozen · **Opened:** 2026-07-29 · **Closed:** 2026-07-30 (close-out reconciled:
PT-R135–PT-R147 minted, PT-C25 minted; PT-R17 superseded by PT-R135, PT-R19 by PT-R145; KI-3 closed)

## Scope

Today the microphone stream is structurally exempt from diarization: every mic utterance is
attributed to the canonical local speaker `You` (PT-R17), and only the system stream is clustered
into speakers. That model breaks for in-person meetings, where two or more people share the user's
microphone — their speech is silently merged into `You`. This project introduces an opt-in
**mic-diarization mode** that behaves exactly like the system channel already does: with the mode
on, the live pass windows-diarizes the mic stream and shows provisional per-speaker labels in
`live.md`, and the refine pass diarizes it globally, reconciles the clusters, and finalizes the
labels in `final.md`. With the mode off — the default — behavior matches today's, with one
deliberate exception: the refine pass gains the mic-echo dedup it is missing (PT-P8-R11).

The mode is controlled at two levels. A **sticky settings toggle** ("diarize microphone", default
off, the `systemAudioEnabled` precedent) governs new recordings: at record start the toggle's value
is **stamped onto the recording** as a per-recording input (a new `options.json` sidecar in the
recording folder — an input, unlike `metadata.json`, which is a refinement output), and both the
live engine and every subsequent refine read the stamp. A **per-recording control** in the
recordings pane shows and edits the stamp, so mic diarization can be applied — or reverted —
**after the fact**: flip the recording's checkbox, hit Refine, and the re-refine regenerates
`final.md` from the persisted WAVs accordingly. Refines always follow the recording's own stamp,
never the ambient global toggle, so an old recording's transcript shape can never silently change
because the setting moved months later.

`You` remains a canonical concept. To keep it canonical when the mic carries several voices, the
engine maintains an **owner voice profile**: a persistent voiceprint centroid in the unified
speaker-embedding space (PT-R112), learned passively from the mic stream of ordinary,
non-mic-diarized recordings (which is by construction almost entirely the user's voice), backfilled
from existing recordings when the mode is first enabled, and corrected through an explicit owner
("this is me") action. In both passes the mic cluster matching the owner profile is labeled `You`;
in the live pass other mic clusters surface as known library names or a provisional `Guest` family
(mirroring the system stream's `Them` family, read-only against library and profile), and in the
refine pass they flow through the existing reconciler (PT-R22/PT-R23) to become ordinary speaker
library entries — placeholder-named, renameable, mergeable, and recognized across meetings and
across channels, because live, offline, and library embeddings already share one space. Attribution
is fail-safe: with no profile or no confident match, no cluster is silently labeled `You`.

The machinery reuses what exists: the diarizer (PT-C3) gains a mic-stream entry point, the live
pipeline (PT-C12/PT-C13) a second windowed diarizer over mic frames, the refinement pipeline
(PT-C4) a conditional mic-diarization stage and an unconditional mic-echo dedup ahead of the merge
(PT-P8-R11), the speaker library (PT-C5) an owner-profile store beside — never inside — the
speaker table, and the merge/metadata tail per-cluster mic labels.
Surfaces follow: the settings toggle and per-recording control in the app (PT-C16), `pulsartrace`
record/refine overrides (PT-C9), the MCP surface (PT-C22), additive `metadata.json` fields
(PT-C11), and events (PT-C6). Along the way the project closes KI-3 by identifying the owner/mic
speaker structurally instead of by the mutable display name `"You"` in the Speaker Edit Service
(PT-C23).

Deliberately out of scope: cross-stream cluster stitching in the live pass (mic and system streams
keep independent provisional label spaces; the refine pass's shared library reconciliation is where
identities converge) and explicit voice-enrollment UX (passive learning, backfill, and "this is
me" cover bootstrap). Echo dedup, by contrast, is deliberately **in** scope: today it exists only
in the live pass — the refine pass re-admits every mic segment, including system-audio
bleed-through — and with mic diarization on that gap would duplicate remote speech in `final.md`,
contaminate mic clusters, and poison owner-profile learning. The refine pass therefore gains the
mic-echo dedup the live pass already has, ahead of mic attribution and profile learning,
superseding PT-R19 — whose body also states the inverse drop direction from what the
implementation does (PT-P8-R11, PT-P8-D13).

## Project Requirements

Each requirement carries a **type** (functional / technical / constraint) and a **change-type**
against the product layer (Introduce / Supersede(target) / Retire(target)). These are mutable drafts
until close-out.

### PT-P8-R1 · Functional · Supersede(PT-R17) — Microphone diarization is an opt-in per-recording mode

By default, microphone-origin speech is attributed to the local speaker `You` and is never sent to
diarization — exactly the behavior PT-R17 mandates today. When a recording's mic-diarization stamp
is on, the recording's mic stream is diarized in **both passes**, mirroring the system stream: the
live pass windows-diarizes it and writes provisional per-speaker labels to `live.md` (PT-P8-R13),
and the refine pass diarizes it globally, reconciles, and finalizes labels in `final.md`
(PT-P8-R4, PT-P8-R5).

*Supersedes:* PT-R17 (mic never diarized) with "mic diarized only when the recording's
mic-diarization stamp is on". *Acceptance:* a recording made and refined with the mode off yields
`live.md`/`final.md`/`metadata.json` byte-equivalent (modulo timestamps) to today's output, except
that refine-side echo dedup (PT-P8-R11) may drop mic-side duplicates today's refine re-admits;
with the mode on, both passes attribute mic speech per cluster.

### PT-P8-R2 · Functional · Introduce — Per-recording stamp in an options sidecar

The mic-diarization state is a per-recording **input** persisted as an `options.json` sidecar in
the recording folder. It is stamped at record start from the global toggle (PT-P8-R12), read by the
live engine at start and by every refine pass, and editable afterward via the app, CLI, and MCP
surfaces. Toggling the stamp and re-refining converges the recording's outputs to the stamp's
state: disabling it restores the single-`You` transcript from the persisted WAVs. Refines follow
the stamp, never the ambient global toggle. A missing or malformed sidecar means all-defaults (mic
diarization off) and never fails a pass. `metadata.json` remains a pure refinement output.

*Acceptance:* enable → refine → disable → refine round-trips to single-`You` output; flipping the
global toggle after a recording exists does not change that recording's refine behavior; a
malformed sidecar refines with defaults.

### PT-P8-R3 · Technical · Introduce — Owner voice profile

The engine maintains a persistent owner voice profile: a centroid in the unified speaker-embedding
space (PT-R112), pinned to the diarization model revision with the same archive-and-reset migration
semantics as the speaker library (PT-R113). It is stored alongside the speaker library but is not a
library speaker — it can never be listed, renamed, merged, delisted, or matched by the reconciler.
It is updated by running mean from four sources: (a) passively, during refinement of
non-mic-diarized recordings, from mic-stream speech that survives the refine pass's echo dedup
(PT-P8-R11), gated by an inlier check so a borrowed microphone does not poison the profile — when
the profile is empty the first sample seeds it and the gate applies from the second onward; (b)
from the `You`-attributed cluster of a mic-diarized refine; (c) from explicit owner designation
(PT-P8-R6); (d) from a one-shot backfill run when the global toggle is first enabled (PT-P8-R12)
and no profile exists, processing existing recordings' mic WAVs newest-first until the centroid
stabilizes, bounded by a fixed cap, so `You` attribution works immediately for established users.
With no profile present, passes proceed; only automatic `You` attribution is unavailable. The live
pass reads the profile read-only, like the speaker library.

*Acceptance:* profile is created/updated across refines of ordinary recordings; first-enable with
existing recordings produces a usable profile without user action; an embedding far from the
existing profile is rejected by the inlier gate; a model-revision change archives and resets the
profile without failing any pass.

### PT-P8-R4 · Functional · Introduce — Fail-safe `You` attribution among mic clusters

In a mic-diarized refine, the mic cluster whose embedding best matches the owner profile at or
above the owner-match threshold — a threshold of its own in the unified space, pinned by a
calibration test like the library match threshold (PT-R112) — is labeled `You`. At most one cluster
is `You`. If no owner profile
exists, or no cluster reaches the threshold, **no cluster is auto-labeled `You`** — all mic clusters
take the guest path (PT-P8-R5) and the user can designate the owner explicitly (PT-P8-R6). `You` is
never assigned by guesswork (e.g. dominant-speaker heuristics). The same rule governs the live
pass's provisional `You` (PT-P8-R13).

*Acceptance:* on a two-speaker mic fixture with a seeded owner profile, the owner's cluster is
labeled `You` and the other is not; with no profile, neither is `You` and both surface as library
speakers.

### PT-P8-R5 · Functional · Introduce — Mic guests are ordinary library speakers

Non-owner mic clusters are reconciled against the speaker library exactly as system-stream clusters
are (PT-R22/PT-R23): matched speakers take their library names and refine their centroids; unmatched
clusters mint `Unknown #N` placeholders. Mic-channel speakers get the full speaker-edit surface
(rename, merge, split, delist, undelist — PT-R105) and are recognized across meetings and across
channels —
the same person reconciles to one library speaker whether they arrived via mic or system stream.

*Acceptance:* a guest speaker recorded on the mic in one recording and on the system stream in
another reconciles to the same `spk_` id; speaker-edit operations on a mic-channel speaker rewrite
`final.md` and emit events identically to system-channel speakers.

### PT-P8-R6 · Functional · Introduce — Explicit owner reassignment

The speaker editor supports designating, per recording, a mic-channel speaker as the owner ("this is
me"): the recording's lines for that speaker re-attribute to `You` via the retroactive `final.md`
rewrite, the owner profile updates from that cluster's embedding, and a library speaker minted
solely from that misattribution — one whose only recorded appearance is this recording's — is
removed. The inverse ("not me") demotes a recording's `You`
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
or impossible; every display-name-keyed guard site keys on the structural marker (the engine's
Speaker Edit Service and the app's speaker-editor view model both carry one today); KI-3 is
removed from the known-issues register at close-out.

### PT-P8-R8 · Functional · Introduce — Settings toggle and per-recording control in the app

The Settings pane gains the sticky mic-diarization toggle (PT-P8-R12). The recordings pane's detail
view shows the recording's stamp as an editable control alongside Refine: flipping it persists the
sidecar, and Refine enqueues a re-refine through the existing job queue (PT-C17) — together the
post-hoc apply/revert flow. During recording, the live transcript window and `live.md` show the
provisional mic labels (PT-P8-R13); recording rows and the detail pane surface mic-channel guests
with the same pills and editor affordances as system speakers.

*Acceptance:* toggle on in Settings → new recording live-shows mic labels and auto-refine produces
mic-diarized output; per-recording control + Refine on a past recording produces it post-hoc;
disabling + re-refine restores single-`You`.

### PT-P8-R9 · Functional · Introduce — CLI and MCP surfaces

`pulsartrace record` and `pulsartrace refine` accept an explicit mic-diarization override that
persists to the recording's sidecar (record: overrides the stamp at start; refine: updates it
before refining, so subsequent refines agree). The MCP surface exposes the same capability on its
record and refine tools, and reports the recording's mic-diarization state in its metadata
responses.

*Acceptance:* CLI overrides round-trip the sidecar and outputs; MCP tools accept the option and
recording queries reflect it.

### PT-P8-R10 · Technical · Introduce — Output-contract evolution

`metadata.json` reports mic diarization: a field recording whether the pass diarized the mic
stream, and per-speaker `is_microphone` loosened to mean "attributed to the microphone stream" (so
several speakers may carry it; `You` keeps `speaker_id: null`, mic guests carry their `spk_` ids).
The new field is additive, but loosening `is_microphone` from exactly-one to possibly-many is a
semantic change to a public contract, so `schema_version` bumps and consumers can key on it. The
`live.md` contract documents the provisional mic label family (PT-P8-R13). New owner-profile and
owner-reassignment events join the events log in causal order and respect the non-content rule
(PT-R84).

*Acceptance:* pre-P8 consumers of `metadata.json` parse post-P8 files unchanged; events for a
mic-diarized refine and an owner reassignment appear in documented causal order with no
content/path leakage.

### PT-P8-R11 · Functional · Supersede(PT-R19) — Microphone-echo dedup in both passes

Mic utterances that duplicate system-stream speech are dropped — the system stream is the
authoritative source of remote speech — in the live pass (today's behavior, unchanged) and, newly,
in the refine pass, where dedup runs before mic segments are attributed (mode on or off) and before
any owner-profile learning (PT-P8-R3). This closes the gap where the refine pass re-admits
bleed-through the live pass dropped — a gap mic diarization makes load-bearing: without it, hybrid
meetings (remote participants on the system stream, several people in the room) would duplicate
remote speech in `final.md` and attribute system-audio bleed-through to mic speakers and the owner
profile.

*Supersedes:* PT-R19, whose body states the inverse drop direction ("a system-side duplicate of
microphone speech is dropped") from what the implementation does and this project needs; the
superseding requirement states the direction correctly and extends coverage to the refine pass.
*Acceptance:* on a paired mic+system fixture with overlapping speech, mic-side duplicates are
absent from `final.md` with the mode off and with it on; mic clusters and owner-profile updates
derive only from mic speech that survived dedup.

### PT-P8-R12 · Functional · Introduce — Sticky global mode toggle

A persisted, default-off settings toggle ("diarize microphone") governs new recordings: its value at
record start is stamped onto the recording (PT-P8-R2). It never retroactively affects existing
recordings — their stamps are edited only through the per-recording surfaces (PT-P8-R8, PT-P8-R9).
First enabling it triggers the owner-profile backfill (PT-P8-R3).

*Acceptance:* toggle persists across app relaunch; recordings started with it on/off carry the
matching stamp; flipping it leaves existing recordings' stamps and refine outputs unchanged.

### PT-P8-R13 · Functional · Introduce — Live-pass mic diarization

With the recording's stamp on, the live pass runs windowed diarization over the mic stream mirroring
the system stream's behavior: the cluster matching the owner profile (read-only) is labeled `You`;
clusters matching library speakers (read-only) surface their names with the existing
pre-reconciliation `?` semantics; remaining clusters take a provisional `Guest` / `Guest #2` family
— distinct from the system stream's `Them` family so hybrid transcripts read unambiguously. The
live pass stays read-only against the library and the owner profile, and `live.md` remains
append-only; with no profile and no library match, mic speech takes provisional guest labels until
refine or explicit designation.

*Acceptance:* on a two-speaker mic fixture with a seeded owner profile, `live.md` carries `You` and
a `Guest`-family label; with the stamp off, `live.md` is unchanged from today; library and profile
files are byte-identical after a live pass.
