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
        /// The display being worked on right now.
        ///
        /// Deliberately *not* `NSScreen.main`. That is the screen of the key
        /// window, and this process is an accessory that usually has none — and
        /// when it does have one it is the island's own panel, which makes the
        /// answer "wherever the island already is" and pins the setting to the
        /// first screen it ever landed on. `NSScreen.main` is also documented
        /// wrong for background apps with "Displays have separate Spaces" off:
        /// it reports the menu-bar screen whatever has focus (FB11506568).
        /// `activeScreen()` asks the pointer instead.
        case main
        /// The built-in display, i.e. the only one that can actually have a notch.
        case builtIn
        /// The screen with a notch, if any is attached.
        case notched
        /// One particular display, chosen by hand in Settings.
        ///
        /// *Which* one lives in `pinnedDisplayID` rather than in the case, so
        /// the preference stays a plain string in `UserDefaults`. Without this
        /// there is no way to say "the external monitor" at all: every other
        /// case describes a role, and on a MacBook driving a second screen
        /// every one of them resolves back to the MacBook.
        case pinned
    }

    /// The display `ScreenPreference.pinned` names, as a `CGDirectDisplayID`.
    ///
    /// Pushed in from `Preferences` — see `AppDelegate.applyChangedPreferences`.
    /// Nil, or an ID that is no longer attached, falls back to the menu-bar
    /// display: unplugging a monitor must not take the island with it.
    public static var pinnedDisplayID: CGDirectDisplayID?

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
        if simulateNotch { return simulatedNotchHeight }
        let inset = screen.safeAreaInsets.top
        if inset > 0 { return inset }
        // A menu bar set to hide itself reports a zero top inset even on a
        // notched panel, which turned a notched Mac into a notchless one for
        // as long as the bar was hidden. The strips either side of the cutout
        // are still reported, and their height is the band it occupies.
        return screen.auxiliaryTopLeftArea?.height ?? 0
    }

    /// Does this display physically have a cutout?
    ///
    /// Ignores `simulateNotch` on purpose: the simulation is about how the
    /// island is *drawn*, not about which piece of glass is which, and letting
    /// it through made every attached screen answer to `.builtIn`.
    static func hasCutout(_ screen: NSScreen) -> Bool {
        screen.safeAreaInsets.top > 0 || screen.auxiliaryTopLeftArea != nil
    }

    /// `CGDirectDisplayID` for a screen.
    ///
    /// The identity to store, because `NSScreen` objects are replaced wholesale
    /// on every display reconfiguration — holding one across a lid close means
    /// holding a screen that no longer exists.
    public static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    /// Pick the display to render on.
    public static func screen(for preference: ScreenPreference) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        switch preference {
        case .primary:
            return primaryScreen()
        case .main:
            return activeScreen()
        case .builtIn:
            return screens.first(where: isBuiltIn) ?? primaryScreen()
        case .notched:
            return screens.first(where: hasCutout) ?? primaryScreen()
        case .pinned:
            return pinnedDisplayID
                .flatMap { id in screens.first { displayID(of: $0) == id } }
                ?? primaryScreen()
        }
    }

    /// The display that owns the menu bar. Every other choice falls back here,
    /// because it is the one display that is always attached.
    public static func primaryScreen() -> NSScreen? {
        let screens = NSScreen.screens
        return screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main
            ?? screens.first
    }

    /// The display being worked on right now — the pointer's screen.
    ///
    /// The pointer is the one signal that is correct for a menu-bar accessory;
    /// see `ScreenPreference.main` for why the obvious `NSScreen.main` is not.
    /// It is still the fallback, for the case where the pointer is somewhere no
    /// screen claims (it can sit exactly on a shared edge, or off the end of a
    /// display arrangement while the mouse is being flicked).
    public static func activeScreen() -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        if let index = NotchMath.screenIndex(
            containing: NSEvent.mouseLocation, in: screens.map(\.frame)
        ) {
            return screens[index]
        }
        return NSScreen.main ?? primaryScreen()
    }

    /// A built-in display reports a notch, or identifies as the Apple panel.
    private static func isBuiltIn(_ screen: NSScreen) -> Bool {
        if hasCutout(screen) { return true }
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
