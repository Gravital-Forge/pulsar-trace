# PT-P8-E5 · Owner identity & reassignment — Specification

**Status:** Frozen · **Opened:** 2026-07-29 · **Closed:** 2026-07-29

## Intent

Implements PT-P8-R6 and PT-P8-R7; touches PT-C23 (Speaker Edit Service), PT-C5 (library), PT-C16
(speaker editor), PT-C6 (events). Two halves. **Identity (R7, closes KI-3):** the label `You`
becomes reserved — `SpeakerLibrary.createSpeaker`/`rename` and `SpeakerEditService` reject it —
and the display-name guards (`SpeakerEditService.delist` ~line 169, `SpeakerEditorViewModel.delist`
~line 231) are replaced: with the name reserved, no library speaker can be `You`, so the mic
speaker (never in the library, `speaker_id: null`) is simply not an editable row; the editor keys
its affordances on `RecordingSpeaker.isMicrophone`/`speakerId == nil`, not on the name.
**Reassignment (R6):** `SpeakerEditService.designateOwner` ("this is me") re-attributes a
recording's mic-channel speaker to `You` via the retroactive rewrite, updates the owner profile
from `mic-diarization.json` (E3), and removes a library speaker minted solely from that
misattribution; `demoteOwner` ("not me") is the inverse — the recording's `You` becomes a
reconciled/minted library speaker and the owner profile subtracts the sample. Both emit new cause
events (`owner_designated` / `owner_demoted`) before their `final_md_rewritten` effects (Hard
Invariant #8).

## Acceptance criteria

- `You` is unassignable as a library name everywhere (create, rename, MCP path via the shared
  service); attempts throw `EditError.reservedName`; KI-3's two scenarios are impossible; the
  known-issues entry is removed at project close-out.
- `designateOwner(recordingId:speakerId:...)`: lines relabel to `You` in that recording only;
  metadata row becomes `label: You, speaker_id: null, is_microphone: true`; owner profile gains
  the cluster embedding (source `owner_designated`); a solely-minted library speaker (only
  appearance = this recording) is deleted, otherwise only the appearance is removed.
- `demoteOwner(recordingId:...)`: the recording's mic `You` lines relabel to a
  reconciled-or-minted library name; metadata row gains the `spk_` id; owner profile subtracts the
  sample (weighted removal, E2-T2).
- Both operations no-op with a clear error when `mic-diarization.json` is absent (recording
  predates E3 or was never mic-diarized).
- Event order: cause before `final_md_rewritten`, asserted by test (same pattern as
  `SpeakerEditServiceTests.renameRewritesAndOrdersEvents`).

## Tasks

- PT-P8-E5-T1 — Reserve `You`; replace both display-name guards (KI-3)
- PT-P8-E5-T2 — `designateOwner` ("this is me")
- PT-P8-E5-T3 — `demoteOwner` ("not me")
- PT-P8-E5-T4 — Speaker-editor actions + event-order tests
