import Foundation
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

enum HostError: LocalizedError {
    case displayNotVisible
    case encoder(String, OSStatus)
    case certificate(String)
    var errorDescription: String? {
        switch self {
        case .displayNotVisible: return "The virtual display never became visible to screen capture."
        case .encoder(let codec, let status): return "Couldn't start the \(codec) encoder (\(status))."
        case .certificate(let message): return "HTTPS setup failed: \(message)"
        }
    }
}

/// Captures the virtual display with ScreenCaptureKit and feeds each new frame to the video encoder.
/// Only changed frames arrive. If the encoder is busy, or the iPad hasn't caught up, the frame is
/// skipped and the newest one is encoded as soon as there's room.
final class Capturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private let config: Config
    private let encoder: VideoEncoder
    // Main queue only: the running stream, and the display it should capture (nil once stopped).
    private var stream: SCStream?
    private var target: CGDirectDisplayID?
    private var size: (width: Int, height: Int)
    private let sampleQueue = DispatchQueue(label: "portrait.capture")
    // All below only touched on sampleQueue.
    private var latest: CVPixelBuffer?
    private var encoding = 0
    private var encodeLatestWhenFree = false
    private var idleRefresh: DispatchWorkItem?
    // Behind a lock rather than read with sampleQueue.sync: the server's stats timer must never wait
    // on this queue, because the encoder's output handler already waits on the server's queue.
    private let statsLock = NSLock()
    private var stats = (captured: 0, encoded: 0, encodeSeconds: 0.0)

    /// How many more frames the iPads can take; frames beyond that aren't encoded at all.
    var freeSlots: () -> Int = { .max }
    /// The running stream stopped by itself (e.g. every display went away when the lid closed). Main queue.
    var onStreamLost: ((Error) -> Void)?

    init(config: Config, encoder: VideoEncoder) {
        self.config = config
        self.encoder = encoder
        size = (config.streamWidth, config.streamHeight)
    }

    /// Main queue. A running capture changes size in place (the display turned); the encoder
    /// follows the frames' size by itself.
    func resize(width: Int, height: Int) {
        guard size != (width, height) else { return }
        size = (width, height)
        stream?.updateConfiguration(configuration()) { error in
            if let error { print("Couldn't resize the screen capture: \(error.localizedDescription)") }
        }
    }

    /// Keyframe for a new or recovering viewer. Re-encodes the last frame, since a still screen
    /// sends no new frames.
    func requestKeyframe() {
        sampleQueue.async {
            self.encoder.requestKeyframe()
            self.encodeLatest()
        }
    }

    /// An iPad caught up: encode the newest frame if one has been waiting.
    func roomAvailable() {
        sampleQueue.async {
            guard self.encodeLatestWhenFree else { return }
            self.encodeLatestWhenFree = false
            self.encodeLatest()
        }
    }

    /// Call on the main queue. `completion` runs on it too, unless `stop()` came first.
    func start(displayID: CGDirectDisplayID, attempt: Int = 0, completion: @escaping (Error?) -> Void) {
        if attempt == 0 { target = displayID }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
            DispatchQueue.main.async {
                guard self.target == displayID else { return }   // stopped meanwhile
                if let error = error {
                    completion(error)
                } else if let display = content?.displays.first(where: { $0.displayID == displayID }) {
                    self.capture(display, completion: completion)
                } else if attempt < 40 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        self.start(displayID: displayID, attempt: attempt + 1, completion: completion)
                    }
                } else {
                    completion(HostError.displayNotVisible)
                }
            }
        }
    }

    private func capture(_ display: SCDisplay, completion: @escaping (Error?) -> Void) {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration(), delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        } catch {
            completion(error)
            return
        }
        stream.startCapture { error in
            DispatchQueue.main.async {
                guard self.target == display.displayID else {   // stopped while starting
                    if error == nil { stream.stopCapture { _ in } }
                    return
                }
                if error == nil { self.stream = stream }
                completion(error)
            }
        }
    }

    private func configuration() -> SCStreamConfiguration {
        let sc = SCStreamConfiguration()
        sc.width = size.width
        sc.height = size.height
        sc.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        // Hand the encoder YUV directly, with the same BT.709 matrix the encoder tags the stream with.
        sc.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        sc.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        sc.colorSpaceName = CGColorSpace.sRGB
        sc.showsCursor = true
        sc.queueDepth = 5
        return sc
    }

    /// Call on the main queue. Capture has to stop before its display is removed; `completion`
    /// (on the main queue) runs once it has, and the last frame is forgotten.
    func stop(completion: @escaping () -> Void) {
        target = nil
        let finish = {
            self.sampleQueue.async {
                self.latest = nil
                self.idleRefresh?.cancel()
                self.encodeLatestWhenFree = false
                DispatchQueue.main.async(execute: completion)
            }
        }
        guard let stream = stream else { finish(); return }
        self.stream = nil
        stream.stopCapture { _ in finish() }
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
        statsLock.withLock { stats.captured += 1 }
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
        DispatchQueue.main.async {
            guard stream === self.stream else { return }   // one we stopped, or one that never started
            self.onStreamLost?(error)
        }
    }

    /// Frames captured and encoded since the last call, and the average encode time.
    func takeStats() -> (captured: Int, encoded: Int, encodeMs: Double) {
        statsLock.withLock {
            let s = stats
            stats = (0, 0, 0)
            return (s.captured, s.encoded, s.encoded > 0 ? s.encodeSeconds / Double(s.encoded) * 1000 : 0)
        }
    }

    // MARK: Encoding

    private func encodeLatest() {   // called on sampleQueue
        guard let buffer = latest else { return }
        // Frames already in the encoder will need room too.
        guard encoding < min(2, freeSlots()) else { encodeLatestWhenFree = true; return }
        encoding += 1
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let started = ProcessInfo.processInfo.systemUptime
        encoder.encode(buffer, time: now) { [weak self] in
            self?.sampleQueue.async {
                guard let self = self else { return }
                self.encoding -= 1
                self.statsLock.withLock {
                    self.stats.encoded += 1
                    self.stats.encodeSeconds += ProcessInfo.processInfo.systemUptime - started
                }
                // A keyframe still pending means the encoder dropped the forced one. On a still
                // screen nothing new would arrive to carry it, so re-encode the last frame now.
                if self.encodeLatestWhenFree || self.encoder.keyframePending {
                    self.encodeLatestWhenFree = false
                    self.encodeLatest()
                }
            }
        }
    }
}
