import Testing
import AVFoundation
import CoreMedia
@testable import PulsarTraceCapture
@testable import PulsarTraceEngine

/// Unit coverage of `SampleBufferConverter` — the `CMSampleBuffer` → canonical
/// 16 kHz mono frame bridge. No audio devices: synthetic buffers are fed in.
///
/// These tests guard `BUG-mic-capture-silent`: a capture device whose native
/// 2-channel format carries an **unknown channel layout** (USB microphones
/// deliver `kAudioChannelLayoutTag_UseChannelDescriptions` with unlabelled
/// channels) was downmixed to pure digital silence by `AVAudioConverter`.
/// `SystemAudioCapture` was unaffected — its `channelCount` configuration
/// yields a proper stereo layout — so the regression slipped past the
/// device-shaped tests, which only ever exercised clean stereo.
@Suite("SampleBufferConverter")
struct SampleBufferConverterTests {

    /// Run `body` with a heap `AudioChannelLayout` for a 2-channel stream that
    /// uses raw channel *descriptions* with unknown labels — the pathological
    /// layout a USB microphone reports, which has no usable downmix.
    private func withUnknownStereoLayout<R>(
        _ body: (UnsafePointer<AudioChannelLayout>, Int) -> R
    ) -> R {
        // `AudioChannelLayout` is a variable-length struct whose declared size
        // already includes one `AudioChannelDescription`; `count` channels
        // therefore need `count - 1` extra strides. `size`, `count`, and the
        // write loop below all describe the same `count` and must stay in sync.
        let count = 2
        let size = MemoryLayout<AudioChannelLayout>.size
            + (count - 1) * MemoryLayout<AudioChannelDescription>.stride
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: size,
            alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { raw.deallocate() }
        let layout = raw.bindMemory(to: AudioChannelLayout.self, capacity: 1)
        layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
        layout.pointee.mChannelBitmap = []
        layout.pointee.mNumberChannelDescriptions = UInt32(count)
        withUnsafeMutablePointer(to: &layout.pointee.mChannelDescriptions) { first in
            for i in 0..<count {
                first[i] = AudioChannelDescription(
                    mChannelLabel: kAudioChannelLabel_Unknown,
                    mChannelFlags: [], mCoordinates: (0, 0, 0))
            }
        }
        return body(layout, size)
    }

    /// An `AVAudioFormat` carrying the unknown-layout pathology — used only to
    /// unit-test `downmixableFormat`. Interleaving is irrelevant to layout
    /// repair; the `CMSampleBuffer` path re-derives its own format from the
    /// buffer's format description, so this need not match the ASBD elsewhere.
    private func unknownLayoutStereoFormat() -> AVAudioFormat {
        withUnknownStereoLayout { layout, _ in
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                interleaved: false,
                channelLayout: AVAudioChannelLayout(layout: layout))
        }
    }

    /// Float32 PCM samples filling every channel of a buffer of `format`.
    private func filledBuffer(
        format: AVAudioFormat, frames: AVAudioFrameCount, value: Float
    ) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            let data = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) { data[i] = value }
        }
        return buffer
    }

    /// Synthesize an interleaved 48 kHz stereo Float32 `CMSampleBuffer` whose
    /// format description carries the unknown-channel-layout pathology — what
    /// a USB microphone delivers through `AVCaptureAudioDataOutput`.
    private func unknownLayoutStereoSampleBuffer(
        frames: Int, value: Float
    ) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)

        let formatDesc: CMAudioFormatDescription? = withUnknownStereoLayout {
            layout, layoutSize in
            var desc: CMAudioFormatDescription?
            guard CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd,
                layoutSize: layoutSize, layout: layout,
                magicCookieSize: 0, magicCookie: nil,
                extensions: nil, formatDescriptionOut: &desc) == noErr
            else { return nil }
            return desc
        }
        guard let formatDesc else { return nil }

        let byteCount = frames * 8  // interleaved, 2 ch × Float32
        let samples = [Float](repeating: value, count: frames * 2)

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
            flags: 0, blockBufferOut: &blockBuffer) == noErr,
            let blockBuffer else { return nil }
        let copied = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard copied == noErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: formatDesc, sampleCount: CMItemCount(frames),
            presentationTimeStamp: .zero, packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer) == noErr else { return nil }
        return sampleBuffer
    }

    @Test("downmixableFormat replaces an unknown 2 ch layout with stereo")
    func downmixableFormatRepairsUnknownLayout() throws {
        let pathological = unknownLayoutStereoFormat()
        #expect(
            pathological.channelLayout?.layoutTag
                == kAudioChannelLayoutTag_UseChannelDescriptions,
            "precondition: the device format has an unknown channel layout")

        let repaired = SampleBufferConverter.downmixableFormat(pathological)
        #expect(repaired.channelLayout?.layoutTag == kAudioChannelLayoutTag_Stereo)
        #expect(repaired.sampleRate == pathological.sampleRate)
        #expect(repaired.isInterleaved == pathological.isInterleaved)

        // A clean stereo format is already downmixable — left unchanged.
        let cleanStereo = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
            channels: 2, interleaved: false)!
        #expect(
            SampleBufferConverter.downmixableFormat(cleanStereo) === cleanStereo,
            "a format that already downmixes must be returned unchanged")
    }

    @Test("an unknown-layout stereo CMSampleBuffer converts to non-silent mono")
    func convertsUnknownLayoutStereoBufferToSignal() throws {
        guard let sampleBuffer = unknownLayoutStereoSampleBuffer(
            frames: 4800, value: 0.5) else {
            Issue.record("could not synthesize a test CMSampleBuffer")
            return
        }

        let converter = SampleBufferConverter()
        let frames = converter.frames(from: sampleBuffer)
        #expect(!frames.isEmpty, "expected canonical frames from the converter")
        #expect(frames.allSatisfy { $0.count == AudioFormat.samplesPerFrame })

        let peak = frames.flatMap { $0 }.map(abs).max() ?? 0
        #expect(peak > 0.1,
                "the converted frames are digital silence — an unknown-layout device buffer was downmixed to zeros (BUG-mic-capture-silent)")
    }
}
