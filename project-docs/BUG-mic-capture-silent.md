# BUG: microphone capture delivers pure silence

**Status:** RESOLVED 2026-05-16 (fix `ee922ea`) ·
**Found:** 2026-05-16 (Epic 9 manual verification) ·
**Repo state at filing:** commit `73a4eab` (Epic 9)

A task brief for a focused debugging session. Self-contained — read this, not
the chat it came from.

## Resolution (2026-05-16)

**Fixed in commit `ee922ea`.** The cause was hypothesis #2 (conversion), not
hypothesis #1 (TCC).

**Root cause.** The fifine's native `AVAudioFormat` — from
`AVAudioFormat(cmAudioFormatDescription:)` — is 48 kHz / 2 ch / Float32 with
channel-layout tag `kAudioChannelLayoutTag_UseChannelDescriptions` (raw,
unlabelled channel *descriptions* rather than a layout tag). `AVAudioConverter`
cannot derive downmix coefficients from that layout and **silently emits an
all-zero mono output** — no error raised. `SystemAudioCaptureEngine` was
unaffected: ScreenCaptureKit's `channelCount` configuration yields a *tagged*
stereo layout the converter downmixes normally.

**Why the rule-outs misled.** `AudioConverter` was "ruled out" because the
system path shares it — but the system path only ever feeds it a clean tagged
stereo layout; the converter had never been fed a layout-less *device* stream.
TCC (hypothesis #1) was disproven directly: `authorizationStatus(for: .audio)`
is `.authorized`, and a stage-by-stage probe showed the raw `CMSampleBuffer`
*and* the `AVAudioPCMBuffer` that `pcmBuffer()` builds both carried real signal
— only `AudioConverter`'s output was zero. A conversion matrix on a real
captured buffer confirmed it: resample-only (16 kHz / 2 ch) and identity
(48 kHz / 2 ch) keep the signal; every 2→1 downmix path produces zeros.

**Fix.** `SampleBufferConverter.downmixableFormat(_:)` — when a 2-channel input
format's layout tag is `UseChannelDescriptions`, rebuild the `AVAudioFormat`
with an explicit `kAudioChannelLayoutTag_Stereo` layout before conversion. The
sample bytes are untouched, so `CMSampleBufferCopyPCMDataIntoAudioBufferList`
still copies correctly.

**Tests added.** `SampleBufferConverterTests` — deterministic and ungated:
synthesizes a `UseChannelDescriptions` `CMSampleBuffer` and fails without the
fix. `DeviceCaptureEngineTests.micEngineCapturesNonSilentAudio` — opt-in device
test (`PULSARTRACE_DEVICE_TESTS=1`) asserting non-silent capture. Together
these close the "test gap" follow-up below.

**Still open** from the follow-ups below: routing `doctor --capture-test`
through `pulsartrace-capture`, and guarding the offline `refine` path against
whisper hallucination on near-silent audio.

The original brief follows, unedited, as the investigation record.

## Symptom

PulsarTrace's microphone capture (`MicCaptureEngine`, AVFoundation) delivers
**pure digital silence** — even though the microphone genuinely works: with the
recording in progress, macOS *System Settings ▸ Sound ▸ Input* shows a live,
moving level meter for the same device ("fifine Microphone").

System-audio capture (`SystemAudioCaptureEngine`, ScreenCaptureKit) works
correctly in the same runs.

## Evidence

All runs below were in a **normal terminal — not sandboxed** — with the mic
**unmuted and working** (input meter confirmed).

1. `pulsartrace record --duration 1 --output /tmp/pt-check` produced:
   - `audio-mic.wav` — 59.7 s, 955 200 samples, **mean & max volume −91.0 dB**
     (digital silence floor).
   - `audio-system.wav` — same run, **mean −42 dB, max −26 dB** (real audio).
2. `pulsartrace doctor --capture-test` → `CaptureSelfTest` → `MicCaptureEngine`:
   **RMS 0.00000**, outcome `.silent`. Device shown: "fifine Microphone".
   Reproduced multiple times.
3. The full sample count arrives (955 200 = 59.7 s @ 16 kHz). So
   `AVCaptureAudioDataOutput`'s delegate (`MicCaptureEngine.captureOutput`) **is
   firing** for the whole session, and `SampleBufferConverter` / `AudioConverter`
   **are producing frames**. The frames just contain all zeros.

> A sandboxed `ffmpeg` capture run by the assistant also showed −91 dB, but the
> mic was muted at that moment *and* it ran inside the Claude Code sandbox —
> **that test is inconclusive, disregard it.** The real bug is items 1–2 above.

## Ruled out

- **`SampleBufferConverter` / `AudioConverter`** — the system-audio path uses
  both and works. The bug is in the part *not* shared with the system path.
- **Device enumeration** — `--list-mics`, `doctor`, and the capture-test all
  correctly name "fifine Microphone".
- **The socket / IPC path** — proven by `IPCTwoDaemonTests` (fixture audio →
  socket → engine → real `You:` utterances).
- **The Claude Code sandbox** — the failing runs (1, 2) were in a normal
  terminal.
- **A muted mic** — the OS input meter shows live audio for the device during
  the failing runs.

## Isolated to

`MicCaptureEngine`'s `AVCaptureSession` microphone path
(`Sources/PulsarTraceCapture/MicCaptureEngine.swift`) — the microphone-specific
code not shared with the working ScreenCaptureKit path.

## Leading hypotheses

1. **Microphone TCC for a CLI / daemon binary (most likely).** `AVCaptureSession`
   may deliver *silent buffers* (not an error) when the capturing binary is not
   itself TCC-recognized for the microphone. `AVCaptureDevice.authorizationStatus`
   returning `.authorized` is misleading — for a bundle-less, unsigned CLI tool
   it reflects the *responsible* process (the terminal), not the binary doing
   the capture. ScreenCaptureKit working does **not** prove the mic works:
   Screen Recording and Microphone are separate TCC grants, enforced separately.
   Note this affects **both** binaries — `record` uses `pulsartrace-capture`,
   `doctor --capture-test` uses `pulsartrace` in-process, and both are silent.
2. **Format handling specific to the mic.** `AVCaptureAudioDataOutput` delivers
   the device's *native* format (unconfigurable on macOS), whereas
   `SystemAudioCaptureEngine` configures `SCStreamConfiguration` to a clean
   48 kHz / 2 ch. If the fifine's native format is something
   `SampleBufferConverter.pcmBuffer` / `AudioConverter` mishandles, the copy
   (`CMSampleBufferCopyPCMDataIntoAudioBufferList`) could yield zeros.
   `AudioConverterTests` only ever exercised 48 kHz stereo.
3. An `AVCaptureSession` wiring issue (missing config, connection not carrying
   audio).

## Suggested first step — decisive

Instrument `MicCaptureEngine.captureOutput(_:didOutput:from:)` to log the
peak / RMS amplitude of the **raw `CMSampleBuffer`** *before* it reaches
`SampleBufferConverter`:

- raw buffer **silent** → the OS hands us silence → hypothesis 1 (TCC/session).
- raw buffer **has signal**, converted output zero → hypothesis 2 (converter).

Then, to separate "our binary" from "the OS path": run a **non-sandboxed**
`ffmpeg -f avfoundation -i ":5" -t 3 out.wav` capture of the fifine and check
it is non-silent (`ffmpeg ... -af volumedetect`). If ffmpeg captures audio but
`MicCaptureEngine` does not, it is our `AVCaptureSession` / TCC, not the device.

If it is TCC: the capture binary likely needs proper code-signing + an
`Info.plist` with `NSMicrophoneUsageDescription`, or the capture must run from
a TCC-blessed bundle. This intersects Epic 10 (signing/notarization).

## Bundled follow-ups (do alongside the fix)

- **Test gap (Epic 7):** `DeviceCaptureEngineTests` for `MicCaptureEngine`
  asserts only that frames *flow* and are *shaped* right — explicitly "not that
  they carry a particular signal". A `MicCaptureEngine` delivering silent
  frames passes Epic 7's suite. Add a device test that plays a known tone and
  asserts captured **RMS above a floor** / a `ToneDetector` frequency match.
- **`doctor --capture-test` architecture:** it captures in-process inside the
  `pulsartrace` binary via `MicCaptureEngine`; R4 designates `pulsartrace-capture`
  as the only TCC-gated capture process. It should drive the daemon instead.
  (This rework does **not** fix the silence — `record` already uses the daemon
  and is equally silent — but it is the correct design.)
- **Refinement hallucination:** on the near-silent input, `pulsartrace refine`
  emitted a hallucinated `final.md` (`Speaker_?: 1.5%` repeated, language
  auto-detected as `nn`/`en` at ~0.4 confidence). The offline refine path
  should detect near-silent audio (RMS floor / whisper no-speech / low
  language-detection confidence) and emit a valid empty transcript with a
  warning, not hallucinated text. Live mode already VAD-gates; the offline
  path needs an equivalent guard.

## Relevant files

- `Sources/PulsarTraceCapture/MicCaptureEngine.swift` — the suspect.
- `Sources/PulsarTraceCapture/SampleBufferConverter.swift` — `CMSampleBuffer` → `AVAudioPCMBuffer`.
- `Sources/PulsarTraceCapture/AudioConverter.swift` — resample/downmix (proven OK by the system path).
- `Sources/PulsarTraceCapture/SystemAudioCaptureEngine.swift` — the working comparison path.
- `Sources/PulsarTraceCapture/CaptureSelfTest.swift` — `doctor --capture-test` capture.
- `Tests/CaptureTests/DeviceCaptureEngineTests.swift` — the device tests with the coverage gap.
