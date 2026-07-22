import Foundation
import CoreGraphics

/// Pure geometry for the underline overlay: coordinate conversion and the squiggle path.
/// Foundation/CoreGraphics only, so it compiles in the plain-swiftc test harness.
enum UnderlineGeometry {
    /// Quartz (top-left origin) -> AppKit (bottom-left origin) screen rect.
    static func appKitRect(fromQuartz rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.origin.x, y: primaryScreenHeight - rect.maxY,
               width: rect.width, height: rect.height)
    }

    /// Zigzag vertices spanning x in [0, width], y alternating between 0 and amplitude.
    /// Degenerate widths yield just the two endpoints.
    static func squigglePoints(width: CGFloat, amplitude: CGFloat, wavelength: CGFloat) -> [CGPoint] {
        guard width > 0, wavelength > 0 else { return [CGPoint(x: 0, y: 0), CGPoint(x: max(0, width), y: 0)] }
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var up = false
        while x < width {
            points.append(CGPoint(x: x, y: up ? amplitude : 0))
            up.toggle()
            x += wavelength / 2
        }
        points.append(CGPoint(x: width, y: up ? amplitude : 0))
        return points
    }

    /// Whether a range's union rect looks single-line next to a one-character probe rect. The AX
    /// bounds API returns one rect for the whole range, so a wrapped range unions into a tall block
    /// that must not get a full-width underline.
    static func isSingleLine(rangeRect: CGRect, probeRect: CGRect) -> Bool {
        guard probeRect.height > 0 else { return false }
        return rangeRect.height <= probeRect.height * 1.5
    }
}
