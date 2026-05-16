import AVFoundation
import CoreMedia

/// Bridges capture-API `CMSampleBuffer`s — the buffers AVFoundation and
/// ScreenCaptureKit deliver — to canonical 16 kHz mono Float32 frames.
///
/// The input format is not known until the first buffer arrives, so the
/// underlying `AudioConverter` is built lazily from that buffer's format and
/// rebuilt if a later buffer's format differs (a device change mid-session,
/// R8). Not thread-safe: the owning capture engine feeds it from a single
/// delivery queue.
final class SampleBufferConverter {

    private var converter: AudioConverter?
    private var inputFormat: AVAudioFormat?

    /// Convert one capture-API sample buffer; returns every complete
    /// 320-sample frame it (with carried-over residual) now yields.
    func frames(from sampleBuffer: CMSampleBuffer) -> [[Float]] {
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else { return [] }
        if inputFormat == nil || inputFormat != pcm.format {
            inputFormat = pcm.format
            converter = try? AudioConverter(inputFormat: pcm.format)
        }
        guard let converter else { return [] }
        return (try? converter.convert(pcm)) ?? []
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
