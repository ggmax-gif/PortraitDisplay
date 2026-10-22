import Foundation
import CoreGraphics
import CGVirtualDisplayPrivate

/// A portrait monitor that only exists in software. It disappears when this program quits.
final class VirtualDisplay {
    private let display: CGVirtualDisplay
    private let config: Config

    var displayID: CGDirectDisplayID { display.displayID }

    init?(config: Config) {
        self.config = config
        let scale = config.hiDPI ? 2 : 1
        let pixelsWide = config.widthPoints * scale
        let pixelsHigh = config.heightPoints * scale

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = config.name
        descriptor.maxPixelsWide = UInt32(pixelsWide)
        descriptor.maxPixelsHigh = UInt32(pixelsHigh)
        let pixelsPerMillimetre = 264.0 / 25.4   // roughly iPad pixel density
        descriptor.sizeInMillimeters = CGSize(width: Double(pixelsWide) / pixelsPerMillimetre,
                                              height: Double(pixelsHigh) / pixelsPerMillimetre)
        descriptor.vendorID = 0xEEEE
        descriptor.productID = 0x1A2B
        descriptor.serialNum = 0x0001
        descriptor.terminationHandler = { _, _ in
            FileHandle.standardError.write("macOS removed the virtual display.\n".data(using: .utf8)!)
        }

        let display = CGVirtualDisplay(descriptor: descriptor)
        guard display.displayID != 0 else { return nil }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = config.hiDPI ? 1 : 0
        var modes = [CGVirtualDisplayMode(width: UInt(config.widthPoints),
                                          height: UInt(config.heightPoints),
                                          refreshRate: 60)]
        if config.hiDPI {
            modes.insert(CGVirtualDisplayMode(width: UInt(pixelsWide),
                                              height: UInt(pixelsHigh),
                                              refreshRate: 60), at: 0)
        }
        settings.modes = modes
        guard display.applySettings(settings) else { return nil }
        self.display = display
    }

    /// Pick the "looks like W×H" mode (Retina when available) using public CoreGraphics API.
    func selectPreferredMode() {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return }
        let w = config.widthPoints, h = config.heightPoints
        let sameSize = modes.filter { $0.width == w && $0.height == h }
        let wantedPixelWidth = config.hiDPI ? w * 2 : w
        let preferred = sameSize.first(where: { $0.pixelWidth == wantedPixelWidth }) ?? sameSize.first
        if let mode = preferred {
            CGDisplaySetDisplayMode(displayID, mode, nil)
        }
    }

    var currentModeDescription: String {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return "unknown" }
        let retina = mode.pixelWidth > mode.width ? " (Retina, \(mode.pixelWidth)×\(mode.pixelHeight) px)" : ""
        return "\(mode.width)×\(mode.height)\(retina)"
    }
}
