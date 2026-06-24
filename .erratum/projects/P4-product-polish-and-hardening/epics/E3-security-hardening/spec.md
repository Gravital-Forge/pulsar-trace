# PT-P4-E3 · Security Hardening — Specification

**Status:** Frozen · **Opened:** 2026-06-09 · **Closed:** 2026-06-10

## Intent

Close the on-disk and cross-process exposure of a local-only privacy product: owner-only content
files and private directories with looser permissions repaired (PT-P4-R4), same-user peer
authentication on internal sockets (PT-P4-R5), and fsync-before-rename durability (PT-P4-R6).
Touches file writing (PT-C4, PT-C11), the Events Log (PT-C6), the Speaker Library (PT-C5), and the
IPC layer (PT-C8).

## Acceptance criteria

- Transcripts, audio, metadata, the event log, and the speaker library are mode 0600; product-owned
  directories are 0700, with looser pre-existing permissions repaired.
- Internal socket servers reject a peer from another user.
- The final transcript and metadata are flushed to disk before the atomic rename.

## Tasks

- PT-P4-E3-T1 — Owner-only files / private directories with permission repair
- PT-P4-E3-T2 — Same-user peer credential check on socket servers
- PT-P4-E3-T3 — fsync before atomic rename; tmp-path redaction in logs
