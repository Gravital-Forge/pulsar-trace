# PT-P8-E5 · Owner identity & reassignment — Completion Record

**Status:** Frozen · **Closed:** 2026-07-29

## What was built

Commit ec756df, two halves:

**Identity (PT-P8-R7, KI-3's guard closed).** `You` is reserved: `SpeakerLibrary.createSpeaker` and
`rename` throw `LibraryError.reservedName`, `SpeakerEditService.rename` pre-checks and surfaces
`EditError.reservedName` (one error for menubar, MCP, and CLI callers), and a reconciler tripwire
test pins that placeholders can never be the reserved name. With the name reserved and the mic owner
never a library row, the display-name guards became dead code and were deleted outright —
`SpeakerEditService.delist`'s name check and `EditError.cannotDelistMicrophone`,
`SpeakerEditorViewModel.delist`'s `"You"` guard and its KI-3 TODO, and `SpeakerEditorView`'s
button-hiding check. The MCP `delist_speaker` description was rewritten accordingly. Three
pre-existing tests that *constructed* a `You` library speaker to assert the old guard now assert the
reservation instead (the old scenario is unrepresentable by design — a passed acceptance). The
known-issues register still lists KI-3; removing it is a close-out step.

**Reassignment (PT-P8-R6).** `SpeakerEditService.designateOwner(recordingId:speakerId:...)` — "this
is me": under the same edit lock and mutate→rewrite→cause→effects order as every edit, it finds the
guest's cluster embedding in `mic-diarization.json` (nearest to the speaker's centroid),
soft-deletes a solely-minted speaker or removes just the appearance (new
`SpeakerLibrary.removeAppearance`, backup-before-write), rewrites that one recording guest→`You`,
nulls the mic row's `speaker_id`, updates the owner profile, and emits `owner_designated` (+
`owner_profile_updated`) before `final_md_rewritten`. `demoteOwner(recordingId:...)` — "not me":
identifies the `You` cluster as the sidecar embedding best-matching the profile (the same rule that
attributed it; fail-safe `noOwnerAttribution` otherwise), reconciles-or-mints via the
promoted-to-shared `SpeakerReconciler.nextUnknownName`, relabels `You`→resolved name, stamps the
resolved `spk_` id on the mic row, subtracts the profile sample, and returns
`EditResult.resolvedSpeakerId` for the UI's undo. Both throw `micDiarizationUnavailable` without the
sidecar.

**Surfaces.** `SpeakerEditorViewModel.designateOwner`/`demoteOwner` run through the `withRewrite`
toast/undo frame (undo is the inverse op; demote-undo consumes `resolvedSpeakerId`);
`canReassignOwner` gates on the sidecar. "This is me" / "Not me" buttons render on the recordings
detail view beside the speaker pills, keyed on `isMicrophone`/`speakerId`, with
`pt.speakerEditor.thisIsMe` / `.notMe` a11y ids.

## Deltas from the task skeleton

- **The rewriter needed a new hook, not the drafted ones.** T2's `removedSpeakerId` would drop the
  mic row entirely (no `You` row), and T3's `remapSpeakerId` can't match a null id. A single
  `setMicOwnerSpeakerId: (matchLabel:, id:)` parameter sets the mic row's id (nulled on designate,
  resolved id on demote), keyed on the row's post-rewrite label + `is_microphone`, with its own
  applies-guard so a no-op recording is still skipped.
- **Button home:** the drafted speaker-editor view is the *global* library editor with no
  per-recording context; owner reassignment is inherently per-recording, so the buttons live on
  `TranscriptDetailView` (which holds folder URL, recording id, and the metadata speaker rows). A11y
  ids and the sidecar gate are as specified.
- View-model tests live in `Tests/MenuBarTests/` (the only target linking `PulsarTraceMenuBar`), not
  the drafted `Tests/UnitTests/` path.
- `removeAppearance` leaves the guest's centroid unchanged on de-attribution (documented; mirrors
  `unmerge`'s best-effort posture).

## Empirical findings worth keeping

- One `You`-asserting test (`WriteToolsLifecycleTests.delistMicRefused`) was invisible to the
  `grep cannotDelistMicrophone` consumer sweep — it asserted via a constructed `You` speaker, not
  the error case. Behavioral sweeps need value-level greps too (`"You"`), not just symbol greps.
- SwiftPM did not recompile already-built test objects after a defaulted-parameter change to a
  public init (mangled-symbol drift); same class of stale-object link failure as E3's. Clean builds
  unaffected.

## Requirements satisfied

- **PT-P8-R6** — designation and demotion round-trip with correct `final.md`, `metadata.json`,
  library, profile, and causal-event outcomes (7 service tests + 3 view-model tests).
- **PT-P8-R7** — the reserved label closes both KI-3 scenarios; every former display-name guard site
  now keys structurally (reservation + `isMicrophone`/null-id), none on the mutable name.

## To flow into the product layer

At close-out: KI-3 leaves the known-issues register; PT-P8-R7's mint records the reservation sites
and the structural keying; PT-P8-R6's mint records the two ops, their events, and the sidecar
dependency (`mic-diarization.json` required for reassignment).
