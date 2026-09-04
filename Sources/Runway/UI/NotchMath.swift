import CoreGraphics
import Foundation

/// The island's placement arithmetic, with no AppKit in it.
///
/// Split out from `NotchGeometry` so it can be exercised without a display:
/// `NSScreen` cannot be constructed in a test, which in the original project
/// meant the two placement bugs that shipped twice — an island 425pt off-centre
/// on a MacBook, and a resting pill narrower than the cutout it sits under —
/// had no cheap regression guard. Everything here is a pure function of
/// numbers, so `spike/CenteringVerify.swift` can check it directly against the
/// real code rather than a re-derivation of it.
public enum NotchMath {
    /// Island widths — the single source of truth.
    public enum Width {
        /// Hovered/expanded, both notched and notchless.
        public static let expanded: CGFloat = 620
        /// Resting on a notchless display: the stacked row list.
        public static let collapsed: CGFloat = 520
        /// Minimum resting width on a notched Mac, when the cutout is narrow.
        public static let minimumNotch: CGFloat = 120

        /// The concave flare either side of the cutout, in points.
        ///
        /// `IslandShape` insets its straight sides by this much to draw the
        /// fillet, so it is dead width as far as content is concerned and live
        /// width as far as the frame is concerned. Twelve points is enough for
        /// the curve to be legible at menu-bar height without the island
        /// visibly overhanging the cutout.
        public static let shoulder: CGFloat = 12

        /// The straight-sided part of the resting island — what actually has to
        /// match the cutout.
        ///
        /// Never narrower than it: a body inset from the notch draws a visible
        /// black seam either side and reads as a rendering fault.
        public static func restingBody(notchWidth: CGFloat) -> CGFloat {
            max(notchWidth, minimumNotch)
        }

        /// Resting *frame* width for a screen: the body plus both shoulders.
        ///
        /// The two differ only under a cutout. Off one there is no flare to pay
        /// for, so the pill's frame is its body.
        public static func resting(hasNotch: Bool, notchWidth: CGFloat) -> CGFloat {
            hasNotch ? restingBody(notchWidth: notchWidth) + shoulder * 2 : collapsed
        }
    }

    /// Collapsed pill size for a screen width.
    public static func collapsedSize(
        screenWidth: CGFloat,
        notchBand: CGFloat,
        rows: Int = 1
    ) -> CGSize {
        let width = min(max(screenWidth * 0.16, 260), 520)
        let rowHeight: CGFloat = 32
        return CGSize(
            width: width,
            height: rowHeight * CGFloat(max(rows, 1)) + 20 + notchBand
        )
    }

    /// Expanded panel size. Taller and wider; height grows with row count.
    public static func expandedSize(
        screenWidth: CGFloat,
        visibleHeight: CGFloat,
        rows: Int
    ) -> CGSize {
        let width = min(max(screenWidth * 0.24, 380), 620)
        let rowHeight: CGFloat = 46
        let chrome: CGFloat = 54
        let maxHeight = max(visibleHeight * 0.6, 200)
        let height = min(chrome + CGFloat(max(rows, 1)) * rowHeight, maxHeight)
        return CGSize(width: width, height: height)
    }

    /// The window's fixed size — big enough for the largest state the island
    /// can reach on this screen.
    ///
    /// **The window never resizes.** Resizing an `NSWindow` in step with a
    /// SwiftUI spring is not possible: the window snaps in one frame while the
    /// content springs over several, so the pill visibly jumps sideways on
    /// expand. The canvas is sized for the worst case instead and the content
    /// animates inside it.
    public static func canvasSize(
        screenWidth: CGFloat,
        visibleHeight: CGFloat,
        notchBand: CGFloat,
        rows: Int
    ) -> CGSize {
        let expanded = expandedSize(screenWidth: screenWidth, visibleHeight: visibleHeight, rows: rows)
        let collapsed = collapsedSize(screenWidth: screenWidth, notchBand: notchBand, rows: 4)
        return CGSize(
            width: max(expanded.width, collapsed.width, Width.expanded),
            height: max(expanded.height + notchBand, collapsed.height)
        )
    }

    /// Where the panel goes, given a screen's measurements.
    ///
    /// `screenFrame` and `visibleFrame` are deliberately separate parameters.
    /// Centring on the visible frame is the 425pt bug: the visible frame
    /// excludes the Dock, so with the Dock on the left its `midX` is half a
    /// Dock-width away from the screen's, and the island lands off-centre under
    /// a cutout that is centred on the *screen*. Horizontal centring uses
    /// `screenFrame`; only the notchless vertical offset uses `visibleFrame`,
    /// because there it must clear the menu bar.
    public static func origin(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        size: CGSize,
        hasNotch: Bool
    ) -> CGPoint {
        let originX = screenFrame.midX - size.width / 2
        let originY: CGFloat

        if hasNotch {
            originY = screenFrame.maxY - size.height
        } else {
            let gap: CGFloat = 6
            originY = visibleFrame.maxY - size.height - gap
        }
        return CGPoint(x: originX.rounded(), y: originY.rounded())
    }

    /// Which screen a point is on, as an index into `frames`.
    ///
    /// Lives here rather than in `NotchGeometry` for the reason everything else
    /// here does: `NSScreen` cannot be built in a test, and "which display is
    /// the pointer on" is arithmetic that is wrong by one whole screen and
    /// still looks plausible in a screenshot.
    ///
    /// Half-open on the far edges, so two abutting displays never both claim a
    /// pointer sitting exactly on the seam between them.
    public static func screenIndex(containing point: CGPoint, in frames: [CGRect]) -> Int? {
        frames.firstIndex { frame in
            point.x >= frame.minX && point.x < frame.maxX
                && point.y >= frame.minY && point.y < frame.maxY
        }
    }

    /// Notch width from the two auxiliary areas either side of the cutout.
    ///
    /// macOS reports the usable menu-bar strips, not the cutout, so the cutout
    /// is what is left over. Clamped at zero: on a screen where the auxiliary
    /// areas are reported but no notch exists, the subtraction can go slightly
    /// negative.
    public static func notchWidth(
        screenWidth: CGFloat,
        leftAreaWidth: CGFloat,
        rightAreaWidth: CGFloat
    ) -> CGFloat {
        max(screenWidth - leftAreaWidth - rightAreaWidth, 0)
    }
}
