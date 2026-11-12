import Foundation
import CoreGraphics

/// An extra monitor that exists only in software. macOS treats it like a real one:
/// it appears in System Settings > Displays and windows can be dragged onto it.
/// It disappears when this object is released.
final class VirtualDisplay {
    static let vendorID: UInt32 = 0x5354

    struct Mode {
        let pointsWide: Int
        let pointsHigh: Int
        let pixelsWide: Int
        let pixelsHigh: Int
    }

    private let display: CGVirtualDisplay

    var displayID: CGDirectDisplayID { display.displayID }

    init?(name: String, pointsWide: Int, pointsHigh: Int, hiDPI: Bool, refreshRate: Double) {
        let scale = hiDPI ? 2 : 1

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.main
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(pointsWide * scale)
        descriptor.maxPixelsHigh = UInt32(pointsHigh * scale)

        // The physical size only sets the DPI macOS reports. This is roughly an 11" tablet.
        let millimetresPerPoint = 25.4 / 135.0
        descriptor.sizeInMillimeters = CGSize(
            width: Double(pointsWide) * millimetresPerPoint,
            height: Double(pointsHigh) * millimetresPerPoint)

        // macOS remembers arrangement per monitor identity. One serial number per
        // size means each resolution keeps its own spot in Displays settings.
        descriptor.vendorID = VirtualDisplay.vendorID
        descriptor.productID = 0x0001
        descriptor.serialNum = (UInt32(pointsWide) << 16) | UInt32(pointsHigh) | (hiDPI ? 0x8000_0000 : 0)

        // sRGB primaries and D65 white point.
        descriptor.redPrimary = CGPoint(x: 0.64, y: 0.33)
        descriptor.greenPrimary = CGPoint(x: 0.30, y: 0.60)
        descriptor.bluePrimary = CGPoint(x: 0.15, y: 0.06)
        descriptor.whitePoint = CGPoint(x: 0.3127, y: 0.3290)

        guard let display = CGVirtualDisplay(descriptor: descriptor) else { return nil }

        // Modes are given in points. With hiDPI on, macOS backs each one with
        // twice as many pixels in both directions.
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        settings.modes = [
            CGVirtualDisplayMode(width: UInt32(pointsWide), height: UInt32(pointsHigh), refreshRate: refreshRate)
        ]
        guard display.apply(settings) else { return nil }

        self.display = display
    }

    /// The mode macOS is actually driving the display in, once it is online.
    func currentMode() -> Mode? {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        return Mode(pointsWide: mode.width, pointsHigh: mode.height,
                    pixelsWide: mode.pixelWidth, pixelsHigh: mode.pixelHeight)
    }
}
