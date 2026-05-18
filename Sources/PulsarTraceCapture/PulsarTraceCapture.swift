/// PulsarTraceCapture — the real device-capture module.
///
/// This module owns the macOS audio APIs: AVFoundation for the microphone and
/// ScreenCaptureKit for system audio. It resamples/downmixes both to the
/// canonical 16 kHz mono Float32 frame format and serves them over Unix domain
/// sockets using `PulsarTraceEngine`'s `FrameProtocol`. The engine consumes
/// those sockets via `SocketSource` and cannot tell device audio from a
/// fixture WAV — the `AudioFrameSource` seam (Hard Invariant #3).
///
/// `pulsartrace-capture` is the *only* process that requires TCC permissions
/// (Microphone + Screen Recording, R4).
enum PulsarTraceCapture {}
