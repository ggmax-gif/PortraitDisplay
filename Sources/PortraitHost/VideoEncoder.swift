import Foundation
import CoreMedia
import VideoToolbox

/// One encoded H.264 frame in AVCC form (4-byte length-prefixed NAL units), which is what
/// WebCodecs expects when the decoder is configured with an avcC `description`.
struct EncodedFrame {
    let data: Data
    let isKey: Bool
}

/// What the iPad's VideoDecoder needs before the first keyframe.
struct CodecConfig: Equatable {
    let codec: String    // e.g. "avc1.640033", built from the SPS profile/level bytes
    let avcC: Data
    let width: Int
    let height: Int
}

/// Hardware H.264 encoder (VideoToolbox) tuned for low latency: no B-frames, no frame delay,
/// keyframes only on request (new viewer, viewer fell behind) or every 10 s.
final class VideoEncoder {
    var onConfig: ((CodecConfig) -> Void)?
    var onFrame: ((EncodedFrame) -> Void)?

    private let session: VTCompressionSession
    private let width: Int
    private let height: Int
    private let lock = NSLock()
    private var forceKey = true          // guarded by lock
    private var lastConfig: CodecConfig?  // only touched in VT's output handler, which is serial

    init(width: Int, height: Int, fps: Int, bitrateMbps: Double) throws {
        self.width = width
        self.height = height

        var created: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: spec,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let session = created else { throw HostError.encoder(status) }
        self.session = session

        let bytesPerSecond = bitrateMbps * 1_000_000 / 8
        let properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 10 as CFNumber),
            // Only a cap: VideoToolbox's hardware H.264 ignores Quality, and with no cap a single
            // keyframe reaches 1.5 MB at level 6.2. Still screens cost almost nothing either way.
            (kVTCompressionPropertyKey_DataRateLimits, [bytesPerSecond, 1] as CFArray),
            (kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
        ]
        for (key, value) in properties {
            let s = VTSessionSetProperty(session, key: key, value: value)
            if s != noErr { print("Note: encoder ignored \(key) (\(s))") }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    func requestKeyframe() {
        lock.lock(); forceKey = true; lock.unlock()
    }

    /// `completion` runs once the frame has been encoded (or dropped by the encoder).
    func encode(_ pixelBuffer: CVPixelBuffer, time: CMTime, completion: @escaping () -> Void) {
        lock.lock()
        let key = forceKey
        forceKey = false
        lock.unlock()
        let options = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let finish = Once(completion)

        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: time, duration: .invalid,
            frameProperties: options, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            if status == noErr, let sampleBuffer = sampleBuffer {
                self?.handle(sampleBuffer)
            } else if key {
                self?.requestKeyframe()   // a dropped keyframe would leave viewers waiting
            }
            finish.run()
        }
        if status != noErr {
            if key { requestKeyframe() }
            finish.run()
        }
    }

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard let format = sampleBuffer.formatDescription,
              let block = sampleBuffer.dataBuffer,
              let data = try? block.dataBytes() else { return }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false

        if !notSync, let config = codecConfig(format), config != lastConfig {
            lastConfig = config
            onConfig?(config)
        }
        onFrame?(EncodedFrame(data: data, isKey: !notSync))
    }

    private func codecConfig(_ format: CMFormatDescription) -> CodecConfig? {
        let atoms = CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
        guard let original = atoms?["avcC"] as? Data, original.count >= 4 else { return nil }
        let avcC = H264NoReorder.patch(avcC: original) ?? original
        // avcC bytes 1–3 are profile_idc, constraint flags and level_idc.
        let codec = "avc1." + avcC[1...3].map { String(format: "%02X", $0) }.joined()
        let dims = format.dimensions
        return CodecConfig(codec: codec, avcC: avcC, width: Int(dims.width), height: Int(dims.height))
    }
}

/// Runs a closure at most once, from whichever thread gets there first.
private final class Once {
    private let lock = NSLock()
    private var body: (() -> Void)?
    init(_ body: @escaping () -> Void) { self.body = body }
    func run() {
        lock.lock(); let b = body; body = nil; lock.unlock()
        b?()
    }
}
