import AppKit
import CoreGraphics

/// Conversions between the coordinate systems in play.
///
/// * **Quartz global** — origin at the top-left of the *main* display, y grows downwards. Used by
///   `CGWindowListCopyWindowInfo`, `CGEvent.location` and the Accessibility API.
/// * **Cocoa global** — origin at the bottom-left of the main display, y grows upwards. Used by
///   `NSScreen` and `NSWindow`.
enum CoordinateConversion {

    /// Height of the primary display, i.e. the reference used by the window server for its flip.
    static var mainDisplayHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// Flips a Quartz-global rect into Cocoa-global coordinates.
    ///
    /// Always flips against the *main* display's height — even for windows and Dock icons that live
    /// on a secondary display — because that is the origin the window server and Dock use.
    static func cocoaRect(fromQuartz rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: mainDisplayHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Flips a Quartz-global point into Cocoa-global coordinates.
    static func cocoaPoint(fromQuartz point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: mainDisplayHeight - point.y)
    }

    /// Flips a Cocoa-global rect back into Quartz-global coordinates (inverse of `cocoaRect`).
    static func quartzRect(fromCocoa rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: mainDisplayHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}


extension CGRect {
    /// Midpoint of the rect, used to decide which screen a frame belongs to.
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
