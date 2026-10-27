import AVFoundation
import UIKit
import VideoToolbox

/// Shows the Mac's stream. Frames are length-prefixed H.264 / HEVC NAL units (AVCC), decoded in
/// hardware by AVSampleBufferDisplayLayer and shown as soon as they arrive: no timestamps, no
/// buffering. The host already marks its streams as having no reordered frames.
final class VideoView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    private var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    /// The decoder failed: the caller asks the Mac for a fresh keyframe.
    var onNeedKeyframe: (() -> Void)?
    private(set) var hasPicture = false

    private var format: CMVideoFormatDescription?
    private var waitingForKey = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    static var decodesHEVC: Bool { VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) }

    /// The codec config the Mac sends before the first keyframe (and after a codec switch):
    /// `{"codec":"avc1…"|"hvc1…","width":…,"height":…,"description":"<base64 avcC / hvcC>"}`.
    func configure(_ config: [String: Any]) {
        guard let codec = config["codec"] as? String,
              let width = config["width"] as? Int, let height = config["height"] as? Int,
              let encoded = config["description"] as? String, let description = Data(base64Encoded: encoded) else { return }
        let hevc = codec.hasPrefix("hvc1")
        let extensions = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [hevc ? "hvcC" : "avcC": description]]
        var created: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
                                       width: Int32(width), height: Int32(height),
                                       extensions: extensions as CFDictionary, formatDescriptionOut: &created)
        format = created
        waitingForKey = true
        displayLayer.sampleBufferRenderer.flush()
    }

    /// One frame: a 1-byte keyframe flag, then the AVCC data.
    func show(_ message: Data) {
        guard message.count > 1, let format else { return }
        let isKey = message[message.startIndex] == 1
        if waitingForKey && !isKey { return }   // deltas are useless until the next keyframe
        waitingForKey = false

        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
            waitingForKey = true
            onNeedKeyframe?()
            return
        }
        guard let sample = Self.sampleBuffer(message.dropFirst(), format: format, isKey: isKey) else { return }
        renderer.enqueue(sample)
        hasPicture = true
    }

    func clear() {
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true)
        hasPicture = false
        waitingForKey = true
    }

    private static func sampleBuffer(_ data: Data, format: CMVideoFormatDescription, isKey: Bool) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                          offsetIntoDestination: 0, dataLength: data.count) }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !isKey {
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sample
    }
}
