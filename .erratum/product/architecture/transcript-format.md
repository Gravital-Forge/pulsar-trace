# PT-C11 · Transcript Output — Contract

The normative specification of the transcript files PulsarTrace writes, a public contract (PT-R89).

## The final transcript

The refinement pass writes the authoritative transcript as Markdown: a header followed by
per-utterance lines in the form `**[HH:MM:SS] Speaker:** text`, timestamped in seconds since
recording start (PT-R13). It carries a completion marker (an HTML comment) that distinguishes it
from provisional output (PT-R38).

## Write discipline

The final transcript is written atomically — temp file, fsync, rename on the same volume — so a
crash cannot leave a truncated file; the prior input transcript is preserved as a backup (PT-R24).

## Metadata sidecar

Alongside the transcript, a JSON sidecar records the recording's id, durations, the speakers
present, the model identities used, and a schema version (PT-R39).

## Speaker labels

Speaker labels in the final transcript are resolved names from the speaker library, or stable
cluster labels where no library identity matched. The microphone speaker is always the local speaker
(PT-R17).

## The live transcript

During capture, a provisional live transcript is written in the same line format. It is created at
session start with a live marker and a header (PT-R35a), is strictly append-only and grows
monotonically (PT-R36), and each line is appended atomically (PT-R12). It is human- and
tool-readable (PT-R35) and carries a marker identifying it as provisional (PT-R37). Live speaker
labels mark the microphone as the local speaker and system speakers as a generic or known-but-
provisional other party (PT-R14, PT-R16, PT-R18); microphone-echo duplicates are dropped (PT-R19). A
provisional speaker is marked with a compact `?` suffix emitted by the engine at the source; an
utterance the live pass cannot attribute to any tracked speaker takes a neutral `Speaker?` marker
rather than a named or numbered party. The verbose `(provisional)` form is the prior schema version
of this field and is still honored on read; the field evolves under the contract's versioning rule
(PT-R89).

## Live-to-final replacement

At refinement, the authoritative final transcript replaces the live transcript: the live file is
preserved as a backup and the final transcript is written with its completion marker. Renames never
happen in the live file — all relabelling is deferred to refinement.
