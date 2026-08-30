import AppKit

/// Where the island panel should sit, on which screen.
@MainActor
public enum NotchGeometry {
    /// Simulate a notch, for developing the notched layout with the lid closed.
    public static var simulateNotch = false
    static let simulatedNotchWidth: CGFloat = 190
    static let simulatedNotchHeight: CGFloat = 32

    /// Which display the island renders on.
    public enum ScreenPreference: String, Sendable, CaseIterable {
        /// The display that owns the menu bar (frame origin `.zero`).
        case primary
        /// The screen with keyboard focus (`NSScreen.main`).
        case main
        /// The built-in display, i.e. the only one that can actually have a notch.
        case builtIn
        /// The screen with a notch, if any is attached.
        case notched
    }

    public struct Placement: Sendable, Equatable {
        /// Panel frame in screen coordinates.
        public var frame: CGRect
        /// True when the panel is tucked under a real notch cutout.
        public var hasNotch: Bool
        /// Notch width in points, 0 when notchless.
        public var notchWidth: CGFloat
        /// Notch height (the menu-bar-thick cutout), 0 when notchless.
        public var notchHeight: CGFloat = 0
        /// The chosen screen's full frame, for debugging.
        public var screenFrame: CGRect
        public var screenName: String
    }

    /// Island widths. Re-exported from `NotchMath` so callers have one name
    /// to reach for; the arithmetic itself lives where it can be tested.
    public typealias Width = NotchMath.Width

    /// Collapsed pill size, sized relative to the screen it lands on.
    public static func collapsedSize(for screen: NSScreen, rows: Int = 1) -> CGSize {
        NotchMath.collapsedSize(
            screenWidth: screen.frame.width,
            notchBand: notchBand(of: screen),
            rows: rows
        )
    }

    /// Expanded panel size. Taller and wider; height grows with row count.
    public static func expandedSize(for screen: NSScreen, rows: Int) -> CGSize {
        NotchMath.expandedSize(
            screenWidth: screen.frame.width,
            visibleHeight: screen.visibleFrame.height,
            rows: rows
        )
    }

    /// The window's fixed size — big enough for the largest state the island
    /// can reach, on this screen. See `NotchMath.canvasSize`.
    public static func canvasSize(for screen: NSScreen, rows: Int) -> CGSize {
        NotchMath.canvasSize(
            screenWidth: screen.frame.width,
            visibleHeight: screen.visibleFrame.height,
            notchBand: notchBand(of: screen),
            rows: rows
        )
    }

    /// Height of the band the cutout occupies, 0 on a notchless display.
    static func notchBand(of screen: NSScreen) -> CGFloat {
        simulateNotch ? simulatedNotchHeight : screen.safeAreaInsets.top
    }

    /// Pick the display to render on.
    public static func screen(for preference: ScreenPreference) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        switch preference {
        case .primary:
            return screens.first(where: { $0.frame.origin == .zero })
                ?? NSScreen.main
                ?? screens.first
        case .main:
            return NSScreen.main ?? screens.first
        case .builtIn:
            return screens.first(where: isBuiltIn) ?? NSScreen.main ?? screens.first
        case .notched:
            return screens.first(where: { $0.safeAreaInsets.top > 0 })
                ?? NSScreen.main
                ?? screens.first
        }
    }

    /// A built-in display reports a notch, or identifies as the Apple panel.
    private static func isBuiltIn(_ screen: NSScreen) -> Bool {
        if screen.safeAreaInsets.top > 0 { return true }
        let name = screen.localizedName.lowercased()
        return name.contains("built-in") || name.contains("liquid retina")
    }

    /// Compute the panel frame for a screen and a content size.
    public static func placement(on screen: NSScreen, size: CGSize) -> Placement {
        let frame = screen.frame
        let notchHeight = notchBand(of: screen)
        let hasNotch = notchHeight > 0

        var notchWidth: CGFloat = simulateNotch ? simulatedNotchWidth : 0
        if !simulateNotch,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            notchWidth = NotchMath.notchWidth(
                screenWidth: frame.width,
                leftAreaWidth: left.width,
                rightAreaWidth: right.width
            )
        }

        let origin = NotchMath.origin(
            screenFrame: frame,
            visibleFrame: screen.visibleFrame,
            size: size,
            hasNotch: hasNotch
        )

        return Placement(
            frame: CGRect(x: origin.x, y: origin.y,
                          width: size.width.rounded(), height: size.height.rounded()),
            hasNotch: hasNotch,
            notchWidth: notchWidth,
            notchHeight: notchHeight,
            screenFrame: frame,
            screenName: screen.localizedName
        )
    }
}
