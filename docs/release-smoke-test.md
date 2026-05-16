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
