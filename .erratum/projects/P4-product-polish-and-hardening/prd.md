# PT-P4 · Product Polish & Hardening — Project PRD

**Status:** Frozen · **Opened:** 2026-05-29 · **Closed:** 2026-06-12

## Scope

This project takes the app from a working debug surface to a finished product. It tunes the live pass
(decode cadence and a language allow-list), refines the speaker and recording experience, hardens the
product on disk and across process boundaries (owner-only files, private directories, peer-authenticated
sockets, durable writes), consolidates the engine internals for maintainability, polishes the UI
(styled transcripts, notifications, accessibility, a hotkey recorder), and reworks the main window into
a master–detail experience with in-window transcript viewing.

It adds product guarantees (privacy hardening, accessibility, notifications, a language policy, speaker
delisting, in-window browsing) and one pure-architecture consolidation that introduces no requirement.
The recognition and diarization engines remain unchanged in kind.

## Project Requirements

All change-types are **Introduce**. The maintainability consolidation (PT-P4-E4) proposes only
architecture changes and introduces no product requirement.

### PT-P4-R1 · Functional · Introduce — Live language allow-list

Per-window live language detection is restricted to a user-configured allow-list rather than ranging
over all languages.

*Introduces:* PT-R102
*Acceptance:* live detection only selects among the configured languages.

### PT-P4-R2 · Functional · Introduce — Speaker delisting and cleaner surfacing

A speaker can be delisted ("don't recognize this speaker") and a non-person per-line fallback is not
surfaced as a speaker, keeping the speaker set meaningful.

*Introduces:* PT-R105
*Acceptance:* a delisted speaker is removed from people and its transcripts rewritten; a no-turn
fallback label earns no speaker pill or metadata entry.

### PT-P4-R3 · Functional · Introduce — In-window recordings and transcript viewing

The main window presents recordings master–detail, renders the selected (including live) transcript
in-window, and supports rename and find-in-transcript.

*Introduces:* PT-R106
*Acceptance:* a recording's transcript — including one recording live — renders in the window and is
searchable; recordings can be renamed.

### PT-P4-R4 · Constraint · Introduce — On-disk privacy

Every content-bearing file is owner-only and product-owned directories are private; looser
pre-existing permissions are repaired.

*Introduces:* PT-R98, PT-R99
*Acceptance:* transcripts, audio, metadata, the event log, and the speaker library are mode 0600;
owned directories are 0700.

### PT-P4-R5 · Constraint · Introduce — Socket peer authentication

Internal Unix-socket servers verify the connecting peer is the same user and reject others.

*Introduces:* PT-R100
*Acceptance:* a connection from another user is rejected.

### PT-P4-R6 · Technical · Introduce — Durable atomic writes

Authoritative outputs are flushed to disk before the atomic rename so a crash cannot leave a truncated
file.

*Introduces:* PT-R101
*Acceptance:* the final transcript and metadata are fsync'd before rename.

### PT-P4-R7 · Constraint · Introduce — Accessibility labels

Interactive controls carry accessibility labels.

*Introduces:* PT-R103
*Acceptance:* status icons, speaker pills, and controls expose VoiceOver labels.

### PT-P4-R8 · Functional · Introduce — Refinement notifications

A system notification is delivered when a refinement completes or fails.

*Introduces:* PT-R104
*Acceptance:* completing or failing a refinement posts a notification (when bundled as an app).
