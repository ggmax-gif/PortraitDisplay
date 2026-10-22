import Foundation
import CoreGraphics
import CoreImage
import CoreMedia
import ImageIO
import ScreenCaptureKit

enum HostError: LocalizedError {
    case displayNotVisible
    var errorDescription: String? {
        switch self {
        case .displayNotVisible: return "The virtual display never became visible to screen capture."
        }
    }
}

/// Captures the virtual display with ScreenCaptureKit and turns each new frame into a JPEG.
/// Only changed frames arrive, and if the encoder is busy only the newest frame is kept.
final class Capturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private let config: Config
    private let onJPEG: (Data) -> Void
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "portrait.capture")
    private let encodeQueue = DispatchQueue(label: "portrait.encode")
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var encoding = false      // only touched on sampleQueue
    private var pending: CIImage?     // only touched on sampleQueue

    init(config: Config, onJPEG: @escaping (Data) -> Void) {
        self.config = config
        self.onJPEG = onJPEG
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
            sc.pixelFormat = kCVPixelFormatType_32BGRA
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

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        if encoding {
            pending = image           // keep only the newest frame
        } else {
            encode(image)
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Screen capture stopped: \(error.localizedDescription)")
        exit(1)
    }

    // MARK: Encoding

    private func encode(_ image: CIImage) {   // called on sampleQueue
        encoding = true
        encodeQueue.async {
            let qualityKey = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
            if let jpeg = self.ciContext.jpegRepresentation(of: image,
                                                            colorSpace: self.colorSpace,
                                                            options: [qualityKey: self.config.quality]) {
                self.onJPEG(jpeg)
            }
            self.sampleQueue.async {
                if let next = self.pending {
                    self.pending = nil
                    self.encode(next)
                } else {
                    self.encoding = false
                }
            }
        }
    }
}
