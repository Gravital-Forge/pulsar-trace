# Changelog

All notable user-visible changes to PulsarTrace are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
There are no tagged releases yet; everything to date is under Unreleased.

## [Unreleased]

### Added

- An opt-in, local **MCP server** lets an AI agent (Claude Code, Codex, …) drive PulsarTrace directly: list recordings and speakers, read the transcript/audio file paths, manage speaker identity (rename / merge / split and their inverses, delist, delete and their inverses), and manage recordings (set a title, request a re-refinement), with a self-describing `manual` tool. It is disabled by default and enabled in Settings, binds the loopback interface only (default port `8276`), and requires a bearer token on every request — Settings shows the live status and a copyable connection command, and offers a manual restart. Edits made over MCP drive the same retroactive `final.md` rewrite as the in-app editor and are refused while a recording is in progress; the surface never changes settings, controls capture, or transits transcript/audio content (agents read it from the returned file paths).
- The Recordings pane is now a master–detail split: the transcript of the selected recording — including the one being recorded right now, streaming live — renders directly in the window. Recordings are grouped by day (Today / Yesterday / weekday / date), filterable by title, speaker, or date, renameable (double-click the title or right-click → Rename), and can be moved to the Trash (⌫ or context menu). The split divider position persists across launches.
- A Record/Stop button in the window toolbar on every pane (with a ticking elapsed timer while recording) and a "Start Recording" call-to-action in the empty recordings list. Pressing it jumps to the live transcript; recordings started from the global hotkey or menubar deliberately do not move your selection.
- Find-in-transcript: ⌘F (or the Find button) opens the system find bar in any transcript view, including the detached live window.
- Crash and start-failure banners in the main window (Recover Transcript / Dismiss), so the window is self-sufficient — these states previously surfaced only in the menubar dropdown.
- System notifications when a refinement finishes ("Transcript ready — N speakers, M min") or fails — delivered when running as a bundled `.app`.
- A determinate progress bar with the current stage in the menubar dropdown while a refinement runs; a failed refinement shows a Retry button and a humanized failure message.
- A default output folder: with none chosen, recordings go to `~/Documents/PulsarTrace`, so the first recording works without any setup.

### Changed

- `pulsartrace speakers rename` / `merge` / `delete` now retroactively rewrite the affected past `final.md` transcripts, instead of mutating the speaker library while leaving old transcripts stale. The CLI, the menubar editor, and the MCP server now share one speaker-edit path, so an edit produces identical file and event effects whoever triggers it; a repeatable `--output-folder <path>` flag points the rewrite at recording folders outside the default `~/Documents/PulsarTrace`.
- Speaker diarization now runs fully in-process on the Apple Neural Engine
  (FluidAudio's CoreML port of pyannote community-1) — the embedded Python
  environment, Hugging Face token, and `python/build-venv.sh` setup step are
  gone. Existing speaker libraries are archived and reset (embeddings moved
  to a new vector space); speakers re-appear as `Unknown #N` on next refine.
  `metadata.json` is now schema v2 (`diarization_model`).
- The Refinements pane is gone — refinement status lives on the recording rows (a steady green check on refined recordings, an orange clock on unrefined ones, queued clock, determinate refining progress, failure badge with Retry) and in the transcript detail's banner (queued/refining with Cancel, "Refinement complete — Show refined transcript", failures with Retry).
- A completed refinement never swaps the transcript you are reading: the banner offers "Show refined transcript" instead.
- **Breaking (file format):** live transcripts mark provisional speakers with a compact `?` suffix (`Them?`, `Them #2?`, `Steve?`) instead of ` (provisional)`. `final.md` is unchanged; `live.md` files recorded before this change keep the old marker until refined.
- One transcript renderer everywhere: text selection now works across lines in recorded transcripts, static transcripts open at the top while live ones follow the newest line, and Copy puts the rendered text on the pasteboard instead of raw Markdown.
- Speaker merge and split moved into the right-click menu: **Merge With ▸ \<speaker\>** folds the chosen speaker into the right-clicked one, and **Split…** opens the split sheet for the right-clicked speaker with their recordings listed — replacing the toolbar buttons that had to be armed by ⌘-click multi-selection and a merge sheet whose operand pickers re-asked what the selection already said. Error and undo banners no longer cover list rows; the split sheet is resizable. Inline renames commit on click-away (Return saves, Escape cancels), in both the Speakers and Recordings lists.
- The sidebar drops the in-window "PulsarTrace" heading and the window opens at 1104×736 (minimum width 800), with the recordings list taking 40% of the split (transcript detail 60%) by default. On unnamed recording rows the duration is rendered smaller and dimmed so it doesn't read as part of the title.
- The menubar dropdown's hover highlight follows the system accent color instead of hardcoded blue-on-white.
- The global hotkey is recorded directly in Settings — click the field and type the shortcut (must include ⌘, ⌃, or ⌥; shown as ⌃⌥⇧⌘ glyphs; a Clear button removes it). Changes take effect immediately.
- Transcripts render as styled rows (timestamp / speaker / text) in both the transcript sheet and the live window, instead of raw Markdown source.
- Recording rows are titled by start time ("Today at 2:30 PM"); the folder name moved to a tooltip.
- The menubar icon distinguishes states at a glance: a red dot badges the waveform's bottom-right corner while recording, and a pulsing sync symbol shows while refining. (The recording icon briefly carried a ticking elapsed timer; it was removed because a ticking status-item label saturates the main thread on macOS 26.5 — the elapsed time ticks in the window toolbar instead, and the dropdown shows the start time.)
- Recording and speaker lists use double-click for the primary action and a right-click context menu instead of always-visible button rows; a single quiet chevron remains as the visible affordance.
- Speaker merge and "Don't recognize this speaker" ask for confirmation first, stating how many recordings will be rewritten; delete stays one-click with an undo toast.
- The undo toast auto-dismisses after ~8 seconds; error banners are dismissible and use accessible contrast.
- The speaker editor disables during a retroactive `final.md` rewrite, with a toolbar spinner until it completes.
- Quit has the standard ⌘Q shortcut; refine-status icons and speaker pills carry VoiceOver labels.

### Fixed

- Starting a recording no longer freezes the app on macOS 26.5: the menubar icon's ticking elapsed timer degenerated into a continuous status-item re-render loop (93% of the main thread), leaving the UI stuck on "Starting" — unable to even close the dropdown — while the recording pipeline ran fine underneath. The icon is now static while recording; the timer ticks in the window toolbar.
- The `live_md_started` event no longer doubles the recording id (`rec_rec-…`): the engine took the orchestrator's already-finished `rec_<short>` id and re-derived a new id from it. It now uses an explicit `--recording-id` verbatim, matching the capture and refinement events so a recording's events join up.
- Opening Recordings/Speakers/Settings from the menubar now brings the window to the front and focuses it. Previously the activation request fired while the dropdown was still closing, and the close handed focus back to the previously active app — leaving the window inactive behind that app's windows.
- The main window no longer comes back greyed out (inactive) after relaunching with it open. macOS restores a menubar app's saved windows without activating the app — and since macOS 14, an app may not activate itself without user interaction backing the request — so the restored window was stuck looking inactive. PulsarTrace now launches quietly (menubar icon only, windows excluded from state restoration); opening the window from the menubar brings it up focused, at its last size and position.
- Microphone and screen-recording permissions are requested and checked before a recording starts, instead of racing the OS prompt mid-start.
- Refinement no longer fails permanently on recordings containing more than ~98 seconds of uninterrupted speech: long speech regions are now split into chunks (cut at the quietest nearby moment) before being sent to whisper, instead of exceeding the transcription channel's frame limit on every retry.
- The green check on a refined recording's row no longer vanishes the moment you select the row (gone until the next app restart): it was modeled as a transient "just refined" notification dismissed by selection. It is now a steady status badge — green check means refined, orange clock means not yet refined.
- Near-silent recordings no longer crash diarization: a speaker whose voice sample is too sparse to fingerprint keeps its spans and label, and refinement completes — previously the whole job failed (`diarizeCrashed`) on every retry. The same fix stops live diarization from discarding such windows mid-recording.
- The recordings list no longer shows a phantom "Unrecognized" speaker. `Unrecognized` is the per-line fallback for speech that overlaps no diarized turn — it labels the line so no text is lost, but it is not a person, so it no longer earns a speaker pill or a row in `metadata.json`'s `speakers` array. (Existing recordings drop the stale pill on their next refine.)

### Security

- Every content-bearing file is owner-only (`0600`) on disk: transcripts (`live.md` / `final.md`), WAV recordings, `metadata.json`, the events log, and the speaker library with its journal and backup — internal lock files too.
- Directories PulsarTrace owns (Application Support, the events log, socket directories) are private (`0700`), with looser pre-existing permissions repaired; recording folders PulsarTrace creates fresh are private too, while existing user-chosen folders are left untouched.
- Both internal Unix-socket servers (audio capture and whisper) verify the connecting peer is the same user and reject anyone else.
- The operational log redacts `$TMPDIR` socket paths in addition to home-directory paths, whisper subprocess stderr included.
- `final.md` and `metadata.json` are flushed to disk (fsync) before the atomic rename, so a crash cannot leave a truncated transcript behind.
