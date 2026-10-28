import Foundation
import CoreGraphics
import CGVirtualDisplayPrivate

/// A portrait monitor that only exists in software. It disappears when this program quits.
/// When the iPad turns sideways it becomes landscape: the same display (same ID, so its windows
/// stay on it) with its settings applied again, since one display only accepts modes of one shape.
final class VirtualDisplay {
    private let display: CGVirtualDisplay
    private let config: Config
    private(set) var landscape: Bool

    var displayID: CGDirectDisplayID { display.displayID }

    init?(config: Config, landscape: Bool) {
        self.config = config
        self.landscape = landscape
        let scale = config.hiDPI ? 2 : 1
        let pixelsWide = config.widthPoints * scale
        let pixelsHigh = config.heightPoints * scale

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = config.name
        // Room for either orientation. (The landscape modes are listed but unusable while the
        // portrait ones are applied, so turning means applying other settings, not picking a mode.)
        descriptor.maxPixelsWide = UInt32(max(pixelsWide, pixelsHigh))
        descriptor.maxPixelsHigh = UInt32(max(pixelsWide, pixelsHigh))
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
        self.display = display
        guard display.applySettings(settings()) else { return nil }
    }

    /// Applies the other orientation's modes; `selectPreferredMode` then picks one once macOS lists them.
    func setLandscape(_ landscape: Bool) {
        self.landscape = landscape
        if !display.applySettings(settings()) { print("macOS refused to turn the virtual display.") }
    }

    private func settings() -> CGVirtualDisplaySettings {
        let size = config.points(landscape: landscape)
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = config.hiDPI ? 1 : 0
        // Screen capture only delivers frames as often as the display refreshes.
        let refreshRate: Double = config.fps > 60 ? 120 : 60
        var modes = [CGVirtualDisplayMode(width: UInt(size.width), height: UInt(size.height), refreshRate: refreshRate)]
        if config.hiDPI {
            modes.insert(CGVirtualDisplayMode(width: UInt(size.width * 2), height: UInt(size.height * 2),
                                              refreshRate: refreshRate), at: 0)
        }
        settings.modes = modes
        return settings
    }

    /// Picks the "looks like W×H" mode (Retina when available) using public CoreGraphics API.
    /// False if macOS doesn't list it yet.
    @discardableResult
    func selectPreferredMode() -> Bool {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return false }
        let (w, h) = config.points(landscape: landscape)
        let sameSize = modes.filter { $0.width == w && $0.height == h && $0.isUsableForDesktopGUI() }
        let wantedPixelWidth = config.hiDPI ? w * 2 : w
        guard let mode = sameSize.first(where: { $0.pixelWidth == wantedPixelWidth }) ?? sameSize.first else { return false }
        CGDisplaySetDisplayMode(displayID, mode, nil)
        return true
    }

    var currentModeDescription: String {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return "unknown" }
        let retina = mode.pixelWidth > mode.width ? " (Retina, \(mode.pixelWidth)×\(mode.pixelHeight) px)" : ""
        return "\(mode.width)×\(mode.height)\(retina) @ \(Int(mode.refreshRate)) Hz"
    }
}
