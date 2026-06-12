# PulsarTrace release smoke-test checklist

A short manual checklist run by a human before tagging each release (R69, PRD
§12 "Layer 6"). It covers what automation genuinely cannot — TCC permission
flows, Gatekeeper, real device switching.

> Status: Epic 1 creates this file. Items are added as the relevant epics land
> their user-facing surfaces. v0.1 (offline CLI) needs only the CLI items;
> the capture/UI items apply from v1.0.

## v0.1 — offline CLI

- [ ] Fresh clone builds: `swift build` succeeds with no errors.
- [ ] The narrow filters listed in CLAUDE.md all green (the broad `swift test --filter PipelineTests` is known-flaky under cross-suite races — see CLAUDE.md).
- [ ] `pytest` green from `python/pulsartrace-ai/` after `python/build-venv.sh`.
- [ ] `pulsartrace --help` prints usage; `pulsartrace version` prints the version.
- [ ] Pipe smoke: `ffmpeg -re -i Tests/Fixtures/audio/single-speaker-30s.wav -f f32le -ac 1 -ar 16000 - | .build/debug/pulsartrace-engine --stdin` reports a frame count.
- [ ] After a clean engine/CLI run, today's `~/Library/Application Support/PulsarTrace/events/*.jsonl` contains an `app_started` and `app_stopped` pair.
- [ ] `~/Library/Logs/PulsarTrace/*.log` exists; a manual read shows no transcript text, speaker names, or full user paths.
- [ ] `pulsartrace refine <recording.wav>` produces a `final.md` with speaker labels (from Epic 4).

## CLI surface (Epic 9)

- [ ] `pulsartrace doctor` prints the environment report; exit code is `0` when nothing failed.
- [ ] `pulsartrace doctor --capture-test` plays a 440 Hz tone and reports a dominant frequency within tolerance (needs a working mic + output; on a BlackHole host, route output→input for a loopback).
- [ ] `pulsartrace record --duration 1 --output /tmp/pt-smoke` records a real meeting and produces `/tmp/pt-smoke/live.md` and a refined `/tmp/pt-smoke/final.md`.
- [ ] `pulsartrace record --list-mics` lists the host's audio input devices with indices.
- [ ] `pulsartrace events tail --no-follow` prints today's events; `--type recording_started` filters to that type only.
- [ ] `pulsartrace install-cli` symlinks into `/usr/local/bin` (or prints the `sudo` command); `pulsartrace install-cli --uninstall` removes it.

## v1.0 — live + UI (added in Epics 6–10)

- [ ] TCC Microphone + Screen Recording grant flow on a fresh user account.
- [ ] TCC re-grant after a macOS update reset the permissions.
- [ ] Hugging Face token paste flow + model download from a fresh state.
- [ ] Manual DMG upgrade from the previous version — speaker library and
      settings persist.
- [ ] Gatekeeper first-launch on a Mac that has never seen the app.
- [ ] Mid-session mic switch (unplug headphones) — recording survives.
- [ ] Mid-session sleep/wake — recording survives, gap logged.
- [ ] Disk-full handling (mount a tiny disk image).

## Menubar UI (Epic 8)

The `pulsartrace-mac` app's surfaces are bindings over `PulsarTraceMenuBar`
ViewModels (unit-tested); these items cover only what needs an interactive
session — `MenuBarExtra` rendering, the global hotkey, audio playback.

- [ ] `MenuBarExtra` icon shows distinct states at a glance: idle waveform,
      red waveform + elapsed timer while recording, pulsing sync symbol while
      refining, and the crashed state.
- [ ] Record a global hotkey in Settings: click the field and type a combo —
      it must include ⌘/⌃/⌥ and displays as ⌃⌥⇧⌘ glyphs; Clear removes it.
      Without relaunching, the hotkey starts and stops a recording from
      another app in the foreground.
- [ ] Settings: change mic, model, output folder, system-audio toggle — all
      persist across an app relaunch.
- [ ] With no output folder ever chosen, the first recording lands in
      `~/Documents/PulsarTrace` (created automatically) instead of failing;
      the mic + screen-recording permission prompts appear *before* the
      recording starts, not mid-start.
- [ ] Start a recording → the live-transcript popover shows styled rows
      (timestamp / speaker / text) in real time.
- [ ] Stop → the refine pass runs — the dropdown shows a determinate progress
      bar with the stage name — and the recordings list picks up the new
      `final.md`.
- [ ] (bundled `.app` only) When the refine completes, a "Transcript ready —
      N speakers, M min" notification arrives; a failed refine posts a
      failure notification, and the Refinements pane offers Retry.
- [ ] Recordings list: rows are titled "Today at 2:30 PM"-style with the
      folder name in the tooltip; double-click (or the chevron) opens the
      transcript; right-click offers View Transcript / Reveal in Finder /
      Refine.
- [ ] Speaker rename in the editor rewrites every past `final.md`; the editor
      disables with a toolbar spinner during the rewrite; a `.bak` sits next
      to each rewritten file.
- [ ] Speaker merge: the confirmation states how many recordings will be
      rewritten; after confirming, the merged speaker is soft-deleted, past
      `final.md` files update; the undo toast (auto-dismisses after ~8 s)
      restores both the library and the transcripts.
- [ ] "Don't recognize this speaker": the confirmation states the rewrite
      count; affected `final.md` lines become "Unrecognized"; undoable for
      30 days.
- [ ] Speaker delete remains one-click — no confirmation, an undo toast.
- [ ] Speaker split, then unsplit — `final.md` labels round-trip.
- [ ] Play-sample on a speaker plays audio.
- [ ] Engine crash mid-recording → the crash state shows; "recover from partial
      WAV" runs a refine.
- [ ] A second start-recording attempt while recording is rejected.
- [ ] Move a recording folder out of the output dir → it disappears from the
      recordings list on the next refresh.
- [ ] Empty speaker library shows the "Record a meeting to get started" state;
      empty recordings list shows its "No recordings yet" state.

## ANE pipeline (D39)

- [ ] **GPU stays free during live + Meet.** Start a Google Meet call with
  screen-share, start a recording, then run
  `sudo powermetrics --samplers gpu_power,ane_power -i 1000 -n 30`.
  Expect: ANE power clearly active during speech; GPU residency/power stays
  near the no-recording baseline (windowed live diarization adds a small
  periodic GPU blip — that is pyannote/MPS, deferred in D39). Meet video and
  screen-share stay fluent. (The old pipeline showed ~90% GPU here.)
- [ ] **Refine beats the old baseline and leaves the GPU free.** Refine
  a long (ideally ~1 h) recording with `large-v3-turbo` while watching
  `sudo asitop`: wall-clock clearly under the audio duration (the old
  GPU large-v3 ran at ~1× real time — that is the baseline to beat), ANE
  busy, GPU near-idle, and foreground work (browser/IDE) stays responsive.
- [ ] **Polish + English end-to-end.** One short Polish recording and one
  English recording: live.md text is in the right language and readable;
  final.md (auto-detect) is correct in both; `metadata.json.language`
  matches.
- [ ] **Language pre-selection.** (a) Settings ▸ "Restrict to languages" =
  Polish only, relaunch, record a short Polish clip: live.md shows no
  wrong-script (Cyrillic) glitches; the queued refine pins `pl`
  (`metadata.json.language == "pl"`). (b) Re-refine the same folder with
  `pulsartrace refine <folder> --language pl`: same result via the
  explicit flag. (c) Restrict to English + Polish, re-refine: the
  detect-among path picks the right one per recording.
- [ ] **First-use downloads emit events.** On a clean
  `~/Library/Caches/PulsarTrace/models/`, the first live + refine runs emit
  `model_downloaded` events for `parakeet-v3` and `large-v3-turbo` with
  non-empty digest `sha256` fields (`pulsartrace events tail`).
