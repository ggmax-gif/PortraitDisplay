import Foundation
import CoreMedia
import VideoToolbox

enum VideoCodec: String {
    case h264, hevc
    var name: String { self == .hevc ? "HEVC" : "H.264" }
}

/// One encoded frame as 4-byte length-prefixed NAL units, which is what WebCodecs expects when
/// the decoder is configured with an avcC / hvcC `description`.
struct EncodedFrame {
    let data: Data
    let isKey: Bool
}

/// What the iPad's VideoDecoder needs before the first keyframe.
struct CodecConfig: Equatable {
    let codec: String    // e.g. "avc1.640033" or "hvc1.1.6.L153.B0", built from the avcC / hvcC header
    let description: Data
    let width: Int
    let height: Int
}

/// Hardware H.264 or HEVC encoder (VideoToolbox) tuned for low latency: no B-frames, no frame delay,
/// keyframes only on request (new viewer, decoder error, viewer fell behind, codec switch) and when
/// the frames change size (the display turned).
final class VideoEncoder {
    var onConfig: ((CodecConfig) -> Void)?
    var onFrame: ((EncodedFrame) -> Void)?

    private var session: VTCompressionSession   // only touched in encode(), on the capturer's queue
    private var sessionCodec: VideoCodec        // same
    private var width: Int                      // same: the session's size
    private var height: Int
    private let fps: Int
    private let bitrateMbps: Double
    private let lock = NSLock()
    private var forceKey = true          // guarded by lock
    private var wantedCodec: VideoCodec  // guarded by lock
    private var lastConfig: CodecConfig?  // only touched in VT's output handler, which is serial

    init(codec: VideoCodec, width: Int, height: Int, fps: Int, bitrateMbps: Double) throws {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrateMbps = bitrateMbps
        session = try Self.makeSession(codec: codec, width: width, height: height, fps: fps, bitrateMbps: bitrateMbps)
        sessionCodec = codec
        wantedCodec = codec
    }

    private static func makeSession(codec: VideoCodec, width: Int, height: Int, fps: Int,
                                    bitrateMbps: Double) throws -> VTCompressionSession {
        var created: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264, encoderSpecification: spec,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let session = created else { throw HostError.encoder(codec.name, status) }

        let bytesPerSecond = bitrateMbps * 1_000_000 / 8
        // HEVC needs no SPS patch like H.264's: with reordering off, VideoToolbox's HEVC SPS
        // already says sps_max_num_reorder_pics = 0.
        let profile = codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel
        var properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_ProfileLevel, profile),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber),
            // No periodic keyframes: each is ~300 KB, a visible hitch on slow Wi-Fi. Viewers ask for
            // one when they join or their decoder fails, and TCP never loses frames in between.
            // (0 is not "no limit" here: it measured a keyframe every ~2 s.)
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, Int32.max as CFNumber),
            // Only a cap: VideoToolbox's hardware H.264 ignores Quality, and with no cap a single
            // keyframe reaches 1.5 MB at level 6.2. Still screens cost almost nothing either way.
            (kVTCompressionPropertyKey_DataRateLimits, [bytesPerSecond, 1] as CFArray),
            (kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
        ]
        if codec == .hevc {
            // Measured on scrolling text at 2048×2668: 38% fewer bits than H.264 at the same quality
            // with this off, but 4 dB worse than H.264 with it on. Costs ~4 ms more per frame.
            // (H.264's output is identical either way. Quality is ignored by both; a QP cap overrides
            // the bitrate cap, ~140 Mbit/s when the whole screen changes.)
            properties.append((kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanFalse))
        }
        for (key, value) in properties {
            let s = VTSessionSetProperty(session, key: key, value: value)
            if s != noErr { print("Note: encoder ignored \(key) (\(s))") }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    func requestKeyframe() {
        lock.lock(); forceKey = true; lock.unlock()
    }

    /// Takes effect at the next frame, which is a keyframe with a new codec config.
    func switchCodec(to codec: VideoCodec) {
        lock.lock(); wantedCodec = codec; forceKey = true; lock.unlock()
    }

    var codec: VideoCodec {
        lock.lock(); defer { lock.unlock() }
        return wantedCodec
    }

    var keyframePending: Bool {
        lock.lock(); defer { lock.unlock() }
        return forceKey
    }

    /// `completion` runs once the frame has been encoded (or dropped by the encoder).
    func encode(_ pixelBuffer: CVPixelBuffer, time: CMTime, completion: @escaping () -> Void) {
        lock.lock()
        var key = forceKey
        forceKey = false
        let wanted = wantedCodec
        lock.unlock()
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        if wanted != sessionCodec || w != width || h != height {
            if replaceSession(codec: wanted, width: w, height: h) { key = true }
        }
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

    /// A new session starts with a keyframe and, through `handle`, a new codec config.
    private func replaceSession(codec: VideoCodec, width: Int, height: Int) -> Bool {
        do {
            let new = try Self.makeSession(codec: codec, width: width, height: height, fps: fps, bitrateMbps: bitrateMbps)
            // Emits the old session's last frames (and runs their completions) before the switch.
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            session = new
            print("Encoder: now \(codec.name) \(width)×\(height).")
            (sessionCodec, self.width, self.height) = (codec, width, height)
            return true
        } catch {
            print("\(error.localizedDescription) Staying with \(sessionCodec.name) \(self.width)×\(self.height).")
            lock.lock(); wantedCodec = sessionCodec; lock.unlock()
            return false
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
        let dims = format.dimensions
        if let hvcC = atoms?["hvcC"] as? Data, hvcC.count >= 23 {
            return CodecConfig(codec: Self.hevcCodecString(hvcC), description: hvcC,
                               width: Int(dims.width), height: Int(dims.height))
        }
        guard let original = atoms?["avcC"] as? Data, original.count >= 4 else { return nil }
        let avcC = H264NoReorder.patch(avcC: original) ?? original
        // avcC bytes 1–3 are profile_idc, constraint flags and level_idc.
        let codec = "avc1." + avcC[1...3].map { String(format: "%02X", $0) }.joined()
        return CodecConfig(codec: codec, description: avcC, width: Int(dims.width), height: Int(dims.height))
    }

    /// ISO 14496-15 Annex E codec string from the hvcC header, e.g. "hvc1.1.6.L153.B0" (Main, level 5.1).
    /// "hvc1" because VideoToolbox keeps VPS/SPS/PPS out of band, in the hvcC only.
    static func hevcCodecString(_ hvcC: Data) -> String {
        let b = [UInt8](hvcC.prefix(13))
        let space = ["", "A", "B", "C"][Int(b[1] >> 6)]
        let tier = b[1] & 0x20 != 0 ? "H" : "L"
        let compatibility = b[2...5].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        var reversed: UInt32 = 0   // the string writes the 32 compatibility flags in reverse bit order
        for bit in 0..<32 where compatibility >> bit & 1 == 1 { reversed |= 1 << (31 - bit) }
        var constraints = Array(b[6...11])
        while constraints.last == 0 { constraints.removeLast() }
        return (["hvc1", "\(space)\(b[1] & 0x1F)", String(reversed, radix: 16, uppercase: true), "\(tier)\(b[12])"]
                + constraints.map { String(format: "%02X", $0) }).joined(separator: ".")
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
