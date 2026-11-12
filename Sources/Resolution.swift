import CoreGraphics
import Foundation

/// Size of the virtual display. Points are what macOS calls "looks like";
/// at 2x every point is backed by 2x2 pixels, like a Retina screen.
struct DisplayGeometry: Equatable {
    var pointsWide: Int
    var pointsHigh: Int
    var hiDPI: Bool

    var scale: Int { hiDPI ? 2 : 1 }
    var pixelsWide: Int { pointsWide * scale }
    var pixelsHigh: Int { pointsHigh * scale }
    var label: String { "\(pointsWide) × \(pointsHigh)" }

    /// H.264 tops out at 4096 x 2304 pixels. Above that, drop to 1x, then shrink.
    func fittedToEncoder() -> DisplayGeometry {
        func fits(_ g: DisplayGeometry) -> Bool {
            g.pixelsWide <= 4096 && g.pixelsHigh <= 2304 && g.pixelsWide * g.pixelsHigh <= 4096 * 2304
        }
        var fitted = self
        if fits(fitted) { return fitted }
        fitted.hiDPI = false
        if !fits(fitted) {
            let shrink = min(4096 / Double(fitted.pointsWide), 2304 / Double(fitted.pointsHigh))
            fitted.pointsWide = Int(Double(fitted.pointsWide) * shrink)
            fitted.pointsHigh = Int(Double(fitted.pointsHigh) * shrink)
        }
        fitted.pointsWide -= fitted.pointsWide % 2
        fitted.pointsHigh -= fitted.pointsHigh % 2
        return fitted
    }
}

enum ResolutionChoice: String, CaseIterable, Identifiable {
    case sameAsMac, largerText, standard, moreSpace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sameAsMac: return "Same as Mac"
        case .largerText: return "Larger Text"
        case .standard: return "Default"
        case .moreSpace: return "More Space"
        }
    }

    /// `tabletPixels` is the tablet's screen in landscape, in real pixels.
    /// `mac` is the Mac's own screen, remembered from before SideTab's display existed.
    func geometry(tabletPixels: CGSize, mac: DisplayGeometry?) -> DisplayGeometry {
        let geometry: DisplayGeometry
        switch self {
        case .sameAsMac:
            geometry = mac ?? Self.tablet(tabletPixels, factor: 1)
        case .largerText:
            geometry = Self.tablet(tabletPixels, factor: 0.8)
        case .standard:
            geometry = Self.tablet(tabletPixels, factor: 1)
        case .moreSpace:
            geometry = Self.tablet(tabletPixels, factor: 1.25)
        }
        return geometry.fittedToEncoder()
    }

    private static func tablet(_ pixels: CGSize, factor: Double) -> DisplayGeometry {
        func even(_ value: Double) -> Int { Int((value / 2).rounded()) * 2 }
        return DisplayGeometry(
            pointsWide: even(Double(pixels.width) / 2 * factor),
            pointsHigh: even(Double(pixels.height) / 2 * factor),
            hiDPI: true)
    }

    /// The Mac's own screen as it is set right now (the main display, or the
    /// first other one if SideTab's display has become the main one).
    static func macGeometry(excluding ownDisplay: CGDirectDisplayID?) -> DisplayGeometry? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }

        let candidates = ids.filter { $0 != ownDisplay && CGDisplayVendorNumber($0) != VirtualDisplay.vendorID }
        let main = CGMainDisplayID()
        guard let chosen = candidates.first(where: { $0 == main }) ?? candidates.first,
              let mode = CGDisplayCopyDisplayMode(chosen)
        else { return nil }

        return DisplayGeometry(
            pointsWide: mode.width,
            pointsHigh: mode.height,
            hiDPI: mode.pixelWidth > mode.width)
    }
}

enum VideoQuality: String, CaseIterable, Identifiable {
    case balanced, high, maximum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced: return "Balanced"
        case .high: return "High"
        case .maximum: return "Maximum"
        }
    }

    /// Bit budget for a 2560 x 1600 picture at 60 fps, scaled with size and frame rate.
    func bitrate(pixels: Int, fps: Int) -> Int {
        let base: Double
        switch self {
        case .balanced: base = 15
        case .high: base = 30
        case .maximum: base = 60
        }
        let scale = Double(pixels) / 4_096_000 * max(0.6, Double(fps) / 60)
        let megabits = min(120, max(8, base * scale))
        return Int(megabits * 1_000_000)
    }
}

enum FrameRate: Int, CaseIterable, Identifiable {
    case thirty = 30, sixty = 60, oneTwenty = 120

    var id: Int { rawValue }
    var title: String { "\(rawValue)" }
}
