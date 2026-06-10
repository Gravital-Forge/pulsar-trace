# Changelog

All notable user-visible changes to PulsarTrace are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
There are no tagged releases yet; everything to date is under Unreleased.

## [Unreleased]

### Added

- System notifications when a refinement finishes ("Transcript ready — N speakers, M min") or fails — delivered when running as a bundled `.app`.
- A determinate progress bar with the current stage in the menubar dropdown while a refinement runs; a failed refinement shows a Retry button and a humanized failure message.
- A default output folder: with none chosen, recordings go to `~/Documents/PulsarTrace`, so the first recording works without any setup.

### Changed

- The global hotkey is recorded directly in Settings — click the field and type the shortcut (must include ⌘, ⌃, or ⌥; shown as ⌃⌥⇧⌘ glyphs; a Clear button removes it). Changes take effect immediately.
- Transcripts render as styled rows (timestamp / speaker / text) in both the transcript sheet and the live window, instead of raw Markdown source.
- Recording rows are titled by start time ("Today at 2:30 PM"); the folder name moved to a tooltip.
- The menubar icon distinguishes states at a glance: a red waveform with an elapsed timer while recording, a pulsing sync symbol while refining.
- Recording and speaker lists use double-click for the primary action and a right-click context menu instead of always-visible button rows; a single quiet chevron remains as the visible affordance.
- Speaker merge and "Don't recognize this speaker" ask for confirmation first, stating how many recordings will be rewritten; delete stays one-click with an undo toast.
- The undo toast auto-dismisses after ~8 seconds; error banners are dismissible and use accessible contrast.
- The speaker editor disables during a retroactive `final.md` rewrite, with a toolbar spinner until it completes.
- Quit has the standard ⌘Q shortcut; refine-status icons and speaker pills carry VoiceOver labels.

### Fixed

- Microphone and screen-recording permissions are requested and checked before a recording starts, instead of racing the OS prompt mid-start.
- Refinement honors the language allow-list from Settings; previously each region auto-detected its language freely, so a quiet stretch could drift to another language.

### Security

- Every content-bearing file is owner-only (`0600`) on disk: transcripts (`live.md` / `final.md`), WAV recordings, `metadata.json`, the events log, and the speaker library with its journal and backup — internal lock files too.
- Directories PulsarTrace owns (Application Support, the events log, socket directories) are private (`0700`), with looser pre-existing permissions repaired; recording folders PulsarTrace creates fresh are private too, while existing user-chosen folders are left untouched.
- Both internal Unix-socket servers (audio capture and whisper) verify the connecting peer is the same user and reject anyone else.
- The operational log redacts `$TMPDIR` socket paths in addition to home-directory paths, whisper subprocess stderr included.
- `final.md` and `metadata.json` are flushed to disk (fsync) before the atomic rename, so a crash cannot leave a truncated transcript behind.
