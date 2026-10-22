import Foundation
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

enum HostError: LocalizedError {
    case displayNotVisible
    case encoder(OSStatus)
    case certificate(String)
    var errorDescription: String? {
        switch self {
        case .displayNotVisible: return "The virtual display never became visible to screen capture."
        case .encoder(let status): return "Couldn't start the H.264 encoder (\(status))."
        case .certificate(let message): return "HTTPS setup failed: \(message)"
        }
    }
}

/// Captures the virtual display with ScreenCaptureKit and feeds each new frame to the H.264 encoder.
/// Only changed frames arrive. If the encoder is busy the frame is skipped, and the newest one is
/// encoded as soon as it frees up.
final class Capturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private let config: Config
    private let encoder: VideoEncoder
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "portrait.capture")
    // All below only touched on sampleQueue.
    private var latest: CVPixelBuffer?
    private var encoding = 0
    private var encodeLatestWhenFree = false
    private var idleRefresh: DispatchWorkItem?

    init(config: Config, encoder: VideoEncoder) {
        self.config = config
        self.encoder = encoder
    }

    /// Keyframe for a new or recovering viewer. Re-encodes the last frame, since a still screen
    /// sends no new frames.
    func requestKeyframe() {
        sampleQueue.async {
            self.encoder.requestKeyframe()
            self.encodeLatest()
        }
    }

    func start(displayID: CGDirectDisplayID, attempt: Int = 0, completion: @escaping (Error?) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
            if let error = error {
                completion(error)
                return
            }
            guard let display = content?.displays.first(where: { $0.displayID == displayID }) else {
                if attempt < 40 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        self.start(displayID: displayID, attempt: attempt + 1, completion: completion)
                    }
                } else {
                    completion(HostError.displayNotVisible)
                }
                return
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let sc = SCStreamConfiguration()
            sc.width = self.config.streamWidth
            sc.height = self.config.streamHeight
            sc.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(self.config.fps))
            // Hand the encoder YUV directly, with the same BT.709 matrix the encoder tags the stream with.
            sc.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            sc.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
            sc.colorSpaceName = CGColorSpace.sRGB
            sc.showsCursor = true
            sc.queueDepth = 5

            let stream = SCStream(filter: filter, configuration: sc, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.sampleQueue)
            } catch {
                completion(error)
                return
            }
            self.stream = stream
            stream.startCapture { error in completion(error) }
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw), status == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        latest = pixelBuffer
        encodeLatest()

        // When the screen goes still, encode the last frame once more. Frames sent during fast
        // motion are capped by the bitrate, and this sharpens what stays on screen.
        idleRefresh?.cancel()
        let refresh = DispatchWorkItem { [weak self] in self?.encodeLatest() }
        idleRefresh = refresh
        sampleQueue.asyncAfter(deadline: .now() + 0.3, execute: refresh)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Screen capture stopped: \(error.localizedDescription)")
        exit(1)
    }

    // MARK: Encoding

    private func encodeLatest() {   // called on sampleQueue
        guard let buffer = latest else { return }
        guard encoding < 2 else { encodeLatestWhenFree = true; return }
        encoding += 1
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        encoder.encode(buffer, time: now) { [weak self] in
            self?.sampleQueue.async {
                guard let self = self else { return }
                self.encoding -= 1
                if self.encodeLatestWhenFree {
                    self.encodeLatestWhenFree = false
                    self.encodeLatest()
                }
            }
        }
    }
}
