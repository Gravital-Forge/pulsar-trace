import AVFoundation
import CoreMedia

/// Bridges capture-API `CMSampleBuffer`s — the buffers AVFoundation and
/// ScreenCaptureKit deliver — to canonical 16 kHz mono Float32 frames.
///
/// The input format is not known until the first buffer arrives, so the
/// underlying `AudioConverter` is built lazily from that buffer's format and
/// rebuilt if a later buffer's format differs (a device change mid-session,
/// PT-R8). Not thread-safe: the owning capture engine feeds it from a single
/// delivery queue.
final class SampleBufferConverter {

    private var converter: AudioConverter?
    private var inputFormat: AVAudioFormat?

    // This method runs per audio frame, so each failure kind is logged once
    // per instance — repeated stderr writes on every frame would be worse
    // than silence.
    private var loggedInitFailure = false
    private var loggedConvertFailure = false

    /// Convert one capture-API sample buffer; returns every complete
    /// 320-sample frame it (with carried-over residual) now yields.
    func frames(from sampleBuffer: CMSampleBuffer) -> [[Float]] {
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else { return [] }
        if inputFormat == nil || inputFormat != pcm.format {
            inputFormat = pcm.format
            converter = try? AudioConverter(inputFormat: pcm.format)
            if converter == nil, !loggedInitFailure {
                loggedInitFailure = true
                log("audio converter init failed — dropping frames for this format")
            }
        }
        guard let converter else { return [] }
        guard let frames = try? converter.convert(pcm) else {
            if !loggedConvertFailure {
                loggedConvertFailure = true
                log("audio conversion failed — frame dropped")
            }
            return []
        }
        return frames
    }

    /// Operational diagnostic to stderr — the daemon's log channel.
    private func log(_ message: String) {
        FileHandle.standardError.write(
            Data("pulsartrace-capture: \(message)\n".utf8))
    }

    /// Drain a final partial frame (zero-padded to 320) at end-of-stream.
    func flush() -> [Float]? {
        converter?.flush()
    }

    /// Repair a 2-channel format whose channel layout `AVAudioConverter`
    /// cannot downmix.
    ///
    /// Some capture devices — notably USB microphones — deliver a 2-channel
    /// stream whose `CMFormatDescription` describes its channels with raw
    /// `kAudioChannelLayoutTag_UseChannelDescriptions` entries rather than a
    /// layout tag. `AVAudioConverter` cannot derive downmix coefficients from
    /// such a layout and silently emits an **all-zero** mono output — the
    /// cause of the "microphone delivers pure silence" bug. `ScreenCaptureKit`
    /// is unaffected: its `channelCount` configuration yields a tagged layout
    /// the converter downmixes normally.
    ///
    /// Substituting the standard stereo layout fixes the downmix without
    /// touching the samples — the byte layout (`commonFormat`, sample rate,
    /// interleaving) is preserved, so `CMSampleBufferCopyPCMDataIntoAudioBufferList`
    /// still copies correctly. Only this 2-channel `UseChannelDescriptions`
    /// pathology is repaired; every other format — a tagged layout, a missing
    /// layout, mono, non-standard PCM, or a 3-or-more-channel device — is
    /// returned unchanged.
    static func downmixableFormat(_ format: AVAudioFormat) -> AVAudioFormat {
        guard format.channelCount == 2,
              format.commonFormat != .otherFormat,
              format.channelLayout?.layoutTag
                == kAudioChannelLayoutTag_UseChannelDescriptions,
              let stereo = AVAudioChannelLayout(
                layoutTag: kAudioChannelLayoutTag_Stereo)
        else { return format }
        return AVAudioFormat(
            commonFormat: format.commonFormat,
            sampleRate: format.sampleRate,
            interleaved: format.isInterleaved,
            channelLayout: stereo)
    }

    /// Copy a `CMSampleBuffer`'s PCM data into an `AVAudioPCMBuffer` carrying
    /// the buffer's own format. Returns `nil` for a non-PCM or empty buffer.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
        else { return nil }
        let format = downmixableFormat(
            AVAudioFormat(cmAudioFormatDescription: formatDescription))

        let sampleCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard sampleCount > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: sampleCount)
        else { return nil }
        pcm.frameLength = sampleCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(sampleCount),
            into: pcm.mutableAudioBufferList)
        guard status == noErr else { return nil }
        return pcm
    }
}
