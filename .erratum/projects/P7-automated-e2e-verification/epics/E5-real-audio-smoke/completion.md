# PT-P7-E5 · Real-Audio Smoke — Completion Record

**Status:** Frozen · **Closed:** 2026-07-28

## What was built

`scripts/e2e-audio-smoke.sh` (PT-P7-R7, per PT-P7-D5) plus its `docs/development.md` section — the
app-level real-audio pass: BlackHole routed as the default output, the committed
`sample-1-roger.mp3` played into it by `afplay`,
`pulsartrace record --duration 1 --mic <idx> --no-system-audio` driving the real capture daemon →
engine live pass → inline refinement, and a 3-of-5 keyword assertion of `final.md` against the
committed reference. Events and logs land in a throwaway `PULSARTRACE_HOME`; the output folder is a
temp dir; both are printed and never auto-deleted. The previous default output device is
trap-restored on every exit path.

**Verified on the dev host 2026-07-28** (M2, macOS 26.5): `PASS`, **5/5 keywords matched**
(adventurous, barista, bookstore, cinnamon, decided), refine 105.3 s on the warm shared cache, 1
speaker, output device restored. `scripts/audio-loopback-check.sh` is byte-identical across the
whole branch (`git diff origin/main...HEAD` empty — the PT-P7-D5 gate).

## Deltas from the task skeleton

- **`PULSARTRACE_MODELS_DIR` share added** (respecting a pre-set override, as `run-ui-tests.sh`
  does). The skeleton omitted it; since `PULSARTRACE_HOME` re-roots the model cache too, the first
  live run saw `cached=false` and spent the entire 60 s recording window downloading Parakeet into
  the throwaway home — SIGTERM at the stop grace timeout, empty recording folder, refine `input`
  failure. Same bug class as E3's containerized-runner cache discovery, one seam over.
- **Short output-folder basename** (`pt-smoke-<stamp>`): the capture daemon's socket path embeds the
  folder basename (`$TMPDIR/PulsarTrace/rec_<name>-mic.sock`) and `sockaddr_un.sun_path` caps at 104
  bytes on Darwin — the skeleton's `pt-audio-smoke-out-<stamp>` overflowed it by exactly one byte
  under the standard `/var/folders` TMPDIR.
- **Capture starts before playback** (record backgrounded, 3 s head start, then `afplay`), mirroring
  the loopback check's sequence — the skeleton played first, risking the sample's keyword-bearing
  opening sentences being clipped while the daemon opens the device.
- Output volume set to 90 on the BlackHole device (per-device; the loopback check's idiom) and a
  Microphone-TCC hint added to the keyword-failure path, per the epic's actionable-failure AC.

## Empirical findings worth keeping

- **Product edge (future fix candidate):** any `pulsartrace record --output` whose folder basename
  exceeds ~33 characters dies at capture-socket bind under the standard darwin TMPDIR ("socket path
  too long"). The session socket name embeds the folder basename verbatim; hashing or truncating it
  would remove the edge. Surfaced by this script's first run.
- **Stop during model download is ungraceful:** an engine still acquiring models when the recording
  stops is SIGTERM'd after the grace period (exit 15) with nothing written — and `record` still
  prints "live pass complete — …/live.md" for a file that does not exist. Cosmetic/robustness wart,
  deliberately not fixed here (no epic AC depends on it).
- The isolated home's own events log made the diagnosis mechanical: `cached=false` at
  `recording_started`, no `model_downloaded`, no `live_md_started`, then
  `refinement_failed error_class=input` — E1's isolation seams doubling as observability.

## Requirements satisfied

- **PT-P7-R7** — the script, its docs section, and the passing dev-host run;
  `audio-loopback-check.sh` preserved unchanged (PT-P7-D5).
- **PT-P7-R9** — all state under the temp home/output roots; the only share is the read-only model
  cache via the explicit `PULSARTRACE_MODELS_DIR` opt-in.

The script's header carries the `PT-P7-R7` link.

## To flow into the product layer

At project close-out: PT-P7-R7's mint gets `implemented_by: scripts/e2e-audio-smoke.sh` (+ the
`docs/development.md` section). Carry the socket-basename product edge forward as a candidate
requirement/fix for a future project (it affects the shipped CLI, not just this script).
