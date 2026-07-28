# PT-P7-E5 · Real-Audio Smoke — Specification

**Status:** Frozen · **Opened:** 2026-07-02 · **Closed:** 2026-07-28

## Intent

Implements PT-P7-R7 per PT-P7-D5; exercises the Capture Daemon (PT-C15) and the Command-Line
Interface (PT-C9) on real audio. One new standalone script drives the shipped record path end to end
on a configured dev host — BlackHole as the microphone, a committed voice sample played into it,
`pulsartrace record` through capture daemon and engine, then a keyword assertion of the refined
transcript against the sample's committed reference. `scripts/audio-loopback-check.sh` stays
byte-identical (user decision, PT-P7-D5).

## Acceptance criteria

- `scripts/e2e-audio-smoke.sh` exits zero on a host set up per `docs/development.md` (BlackHole 2ch
  installed, terminal has Microphone TCC), printing which reference keywords matched; exits non-zero
  with an actionable message when prerequisites are missing.
- The system default output device is restored on every exit path.
- Recording runs mic-only through the real capture daemon into an isolated temp output folder
  (`PULSARTRACE_HOME` isolation for events; PT-P7-R9); nothing lands in the user's real state.
- `git diff` shows `scripts/audio-loopback-check.sh` untouched.
- `docs/development.md` documents the script next to the existing hardware-test setup.

## Tasks

- PT-P7-E5-T1 — `scripts/e2e-audio-smoke.sh`.
- PT-P7-E5-T2 — `docs/development.md` section.
