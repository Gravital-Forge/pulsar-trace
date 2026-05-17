# PulsarTrace release smoke-test checklist

A short manual checklist run by a human before tagging each release (R69, PRD
§12 "Layer 6"). It covers what automation genuinely cannot — TCC permission
flows, Gatekeeper, real device switching.

> Status: Epic 1 creates this file. Items are added as the relevant epics land
> their user-facing surfaces. v0.1 (offline CLI) needs only the CLI items;
> the capture/UI items apply from v1.0.

## v0.1 — offline CLI

- [ ] Fresh clone builds: `swift build` succeeds with no errors.
- [ ] `swift test --filter Unit` and `swift test --filter Pipeline` both green.
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

- [ ] `MenuBarExtra` icon appears; it changes between idle / recording /
      refining / crashed.
- [ ] The configurable global hotkey starts and stops a recording from another
      app in the foreground.
- [ ] Settings: change mic, model, output folder, system-audio toggle — all
      persist across an app relaunch.
- [ ] Start a recording → the live-transcript popover shows lines in real time.
- [ ] Stop → the refine pass runs and the recordings list picks up the new
      `final.md`.
- [ ] Speaker rename in the editor rewrites every past `final.md`; a `.bak`
      sits next to each rewritten file.
- [ ] Speaker merge: the merged speaker is soft-deleted, past `final.md` files
      update; the undo toast restores both the library and the transcripts.
- [ ] Speaker split, then unsplit — `final.md` labels round-trip.
- [ ] Play-sample on a speaker plays audio.
- [ ] Engine crash mid-recording → the crash state shows; "recover from partial
      WAV" runs a refine.
- [ ] A second start-recording attempt while recording is rejected.
- [ ] Move a recording folder out of the output dir → it disappears from the
      recordings list on the next refresh.
- [ ] Empty speaker library shows the "Record a meeting to get started" state;
      empty recordings list shows its "No recordings yet" state.
