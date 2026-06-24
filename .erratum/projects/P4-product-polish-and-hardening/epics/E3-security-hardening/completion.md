# PT-P4-E3 · Security Hardening — Completion Record

**Status:** Frozen · **Closed:** 2026-06-10

## What was built

`SecureFiles` makes every content-bearing file owner-only (0600) — transcripts, WAVs, metadata, the
event log, the speaker library and its journal/backup, and internal lock files — and product-owned
directories private (0700), repairing looser pre-existing permissions while leaving user-chosen
folders untouched. Both internal Unix-socket servers verify the connecting peer is the same user via
`PeerCredentials` and reject anyone else. `AtomicFile` fsyncs authoritative outputs before the rename
so a crash cannot leave a truncated transcript, and `PathRedactor` extends log redaction to socket
paths under the temporary directory.

## Deltas from the spec

None.

## Requirements satisfied

| Project Requirement | Where |
| ------------------- | ----- |
| PT-P4-R4 | `Sources/PulsarTraceEngine/Support/SecureFiles.swift` |
| PT-P4-R5 | `Sources/PulsarTraceEngine/Support/PeerCredentials.swift`; socket servers in `PulsarTraceCapture` (`CaptureSocketServer`) and the `pulsartrace-whisper` subprocess |
| PT-P4-R6 | `Sources/PulsarTraceEngine/Support/AtomicFile.swift`, `PathRedactor.swift` |

## To flow into the product layer

- Mint a Security & Privacy Hardening component covering file/dir permissions, peer auth, and durable
  writes; note peer auth on the IPC layer and durable writes on Transcript Output.
- Mint product requirements PT-R98 (owner-only files), PT-R99 (private directories), PT-R100 (socket
  peer authentication), PT-R101 (durable atomic writes).
