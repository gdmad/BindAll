import Foundation
import CoreGraphics

/// Pure geometry for the underline overlay: coordinate conversion and the underline's placement.
/// Foundation/CoreGraphics only, so it compiles in the plain-swiftc test harness.
enum UnderlineGeometry {
    /// Quartz (top-left origin) -> AppKit (bottom-left origin) screen rect.
    static func appKitRect(fromQuartz rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.origin.x, y: primaryScreenHeight - rect.maxY,
               width: rect.width, height: rect.height)
    }

    /// How far below a word's rect the underline hangs. The AX bounds of a word include its
    /// descenders, so a line drawn on the bottom edge cuts through them; this drops it clear of
    /// the text. AppKit coordinates (y grows upward), so it is subtracted from the rect's minY.
    static let underlineDrop: CGFloat = 3

    /// Stroke width of the underline.
    static let underlineThickness: CGFloat = 2

    /// Whether a range's union rect looks single-line next to a one-character probe rect. The AX
    /// bounds API returns one rect for the whole range, so a wrapped range unions into a tall block
    /// that must not get a full-width underline.
    static func isSingleLine(rangeRect: CGRect, probeRect: CGRect) -> Bool {
        guard probeRect.height > 0 else { return false }
        return rangeRect.height <= probeRect.height * 1.5
    }
}
