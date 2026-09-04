import AppKit
import SwiftUI

/// One motion vocabulary for the whole island.
public enum Motion {
    /// Island arriving on screen.
    public static let entry = Animation.spring(duration: 0.42, bounce: 0.30)
    /// Island leaving.
    public static let exit = Animation.easeInOut(duration: 0.44)

    /// Hover expansion.
    public static let expand = Animation.spring(duration: 0.40, bounce: 0.26)
    /// Hover collapse — slightly faster and flatter than the expand.
    public static let collapse = Animation.spring(duration: 0.32, bounce: 0.12)
    /// Content changing inside the pill (status flips, job dots appearing).
    public static let content = Animation.spring(duration: 0.34, bounce: 0.18)

    /// Window alpha ramps, in seconds.
    public static let fadeIn: TimeInterval = 0.22
    /// Longer than `exit` on purpose: the shape must finish moving while still visible.
    public static let fadeOut: TimeInterval = 0.52
}

/// A borderless, non-activating panel pinned to the top of the chosen screen.
final class IslandPanel: NSPanel {
    /// Borderless windows are not key by default, which would break hover and clicks.
    override var canBecomeKey: Bool { true }
    /// Never main — this is an accessory, it must not own the menu bar.
    override var canBecomeMain: Bool { false }
}

/// The content view: transparent outside the drawn pill.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    /// Height of the region that should accept the mouse, from the top of the window.
    var interactiveHeight: CGFloat = 0
    /// Width of that region, centred horizontally.
    var interactiveWidth: CGFloat = 0

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactiveHeight > 0, interactiveWidth > 0 else {
            return super.hitTest(point)
        }
        let top = bounds.maxY
        let left = bounds.midX - interactiveWidth / 2
        let islandRect = CGRect(
            x: left,
            y: top - interactiveHeight,
            width: interactiveWidth,
            height: interactiveHeight
        )
        guard islandRect.contains(point) else { return nil }
        return super.hitTest(point)
    }
}

/// Owns the panel, its hosting view, and its placement across screen changes.
@MainActor
public final class NotchPanelController {
    private let panel: IslandPanel
    private let model: IslandModel
    private let hostingView: PassthroughHostingView<AnyView>
    private let onOpen: (WorkflowRun) -> Void
    private let onDismiss: (WorkflowRun) -> Void
    private let onQuit: () -> Void

    /// Which display to render on.
    public var screenPreference: NotchGeometry.ScreenPreference = .primary {
        didSet {
            followActiveDisplay(screenPreference == .main)
            reposition()
        }
    }

    /// Whether the island should stay on screen with nothing running.
    ///
    /// The preference as the user set it. It is AND-ed with the cutout here
    /// rather than in the model, because this is the only object that knows
    /// there is one: off a notch the resting island is a floating pill under
    /// the menu bar, and a pill that never leaves is furniture. See `IdleMark`.
    public var showsIdleMark = false {
        didSet { applyIdlePresence() }
    }

    /// Where the resting mark sits in its band. Straight through to the model —
    /// unlike `showsIdleMark` there is nothing about the display to AND it with.
    public var idleMarkPosition: IdleMarkPosition = .center {
        didSet { model.idleMarkPosition = idleMarkPosition }
    }

    /// What colour that mark is drawn in. Straight through to the model, for
    /// the same reason the position is.
    public var idleMarkTint: IdleMarkTint = .white {
        didSet { model.idleMarkTint = idleMarkTint }
    }

    private var currentPlacement: NotchGeometry.Placement?
    /// The display the panel is currently on, so a move between screens can be
    /// told apart from a resize on the one it is already on.
    private var currentDisplayID: CGDirectDisplayID?
    /// Global pointer monitor, installed only while following the active display.
    private var pointerMonitor: Any?
    /// Rate limit for that monitor — see `pointerMoved`.
    private var lastPointerCheck: TimeInterval = 0
    /// Notification tokens, kept per centre.
    ///
    /// A token only unregisters from the centre that issued it, so one shared
    /// array made `invalidate()` half a no-op: the workspace observer below was
    /// handed to `NotificationCenter.default`, which had never heard of it, and
    /// stayed registered for the life of the process.
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    /// Called after the hover expansion changes.
    ///
    /// Expansion pins the island on screen, so collapsing it can be the moment a
    /// run that has already aged out should disappear. Nothing else would notice
    /// that: the model's ticker stops once no run is relevant.
    public var onExpansionChange: (() -> Void)?

    /// Intended visibility, which differs from `panel.isVisible` mid-fade.
    private var isShown = false

    public init(
        model: IslandModel,
        onOpen: @escaping (WorkflowRun) -> Void,
        onDismiss: @escaping (WorkflowRun) -> Void = { _ in },
        onQuit: @escaping () -> Void
    ) {
        self.model = model
        self.onOpen = onOpen
        self.onDismiss = onDismiss
        self.onQuit = onQuit

        panel = IslandPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.animationBehavior = .none

        hostingView = PassthroughHostingView(rootView: AnyView(EmptyView()))
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        reposition()
        updateRootView()
        observeScreenChanges()
    }

    /// Drop the notification observers, each from the centre that issued it.
    public func invalidate() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        workspaceObservers.removeAll()
        followActiveDisplay(false)
    }

    /// Corner treatment differs under a cutout, so rebuild when it changes.
    private func updateRootView() {
        hostingView.rootView = AnyView(
            IslandView(
                model: model,
                hasNotch: currentPlacement?.hasNotch ?? false,
                notchHeight: currentPlacement?.notchHeight ?? 0,
                notchWidth: currentPlacement?.notchWidth ?? 0,
                onOpen: onOpen,
                onDismiss: onDismiss,
                onQuit: onQuit,
                onHoverChange: { [weak self] hovering in
                    self?.setExpanded(hovering)
                }
            )
        )
    }

    // MARK: - Visibility

    /// Cross-fade the panel in and out instead of popping it.
    public func setVisible(_ visible: Bool) {
        guard visible != isShown else { return }
        isShown = visible

        if visible {
            model.isExpanded = false
            applyFrame()

            panel.alphaValue = 0
            panel.orderFrontRegardless()

            model.isLeaving = false
            model.isOnScreen = false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                withAnimation(Motion.entry) { self.model.isOnScreen = true }
            }

            updateInteractiveRegion()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.fadeIn
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        } else {
            model.isLeaving = true
            withAnimation(Motion.exit) { model.isOnScreen = false }

            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.fadeOut
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                // Runs on the main thread, but the closure is nonisolated under
                // Swift 6. Asserting that beats hopping through a Task, which
                // would order the panel out a frame later than the fade ends.
                MainActor.assumeIsolated {
                    guard let self, !self.isShown else { return }
                    self.panel.orderOut(nil)
                }
            }
        }
    }

    public var isVisible: Bool { panel.isVisible }

    /// Panel frame in screen coordinates.
    public var frame: CGRect { panel.frame }

    public var placement: NotchGeometry.Placement? { currentPlacement }

    // MARK: - Expansion

    public func setExpanded(_ expanded: Bool) {
        guard expanded != model.isExpanded else { return }
        if expanded { Haptics.expanded() }
        withAnimation(expanded ? Motion.expand : Motion.collapse) {
            model.isExpanded = expanded
        }
        updateInteractiveRegion()
        onExpansionChange?()
    }

    /// Tell the hosting view how much of the canvas the island actually covers.
    public func refreshInteractiveRegion() { updateInteractiveRegion() }

    private func updateInteractiveRegion() {
        let hasNotch = currentPlacement?.hasNotch ?? false
        let notchWidth = currentPlacement?.notchWidth ?? 0
        let notchHeight = currentPlacement?.notchHeight ?? 0

        if model.isExpanded {
            hostingView.interactiveWidth = NotchGeometry.Width.expanded
            hostingView.interactiveHeight = panel.frame.height
            return
        }

        if hasNotch {
            hostingView.interactiveWidth = NotchGeometry.Width.resting(
                hasNotch: true, notchWidth: notchWidth
            )
            // The cutout, plus the band the island hangs below it: a 17pt
            // rest row and 5pt of padding at its tallest, which is the idle
            // mark. Hovering has to reach the whole of what is drawn — the
            // mark is the part people aim at.
            hostingView.interactiveHeight = notchHeight + 24
            return
        }

        let rows = max(model.collapsedRuns.count, 1)
        let rowHeight: CGFloat = 32
        let chrome: CGFloat = 20
        hostingView.interactiveWidth = NotchGeometry.Width.collapsed
        hostingView.interactiveHeight = rowHeight * CGFloat(rows) + chrome
    }

    // MARK: - Placement

    public func reposition() {
        applyFrame()
    }

    /// Push the resolved idle presence into the model, and open or close the
    /// panel if it changed.
    ///
    /// Called on every placement pass as well as on the setter, because moving
    /// to an external display is exactly the moment the answer changes without
    /// anybody touching the preference.
    private func applyIdlePresence() {
        let shows = showsIdleMark && (currentPlacement?.hasNotch ?? false)
        guard shows != model.showsIdleMark else { return }
        model.showsIdleMark = shows
        setVisible(model.isVisible)
    }

    private func applyFrame() {
        guard let screen = NotchGeometry.screen(for: screenPreference) else { return }

        let size = NotchGeometry.canvasSize(for: screen, rows: 8)
        let placement = NotchGeometry.placement(on: screen, size: size)
        let notchChanged = placement.hasNotch != currentPlacement?.hasNotch
            || placement.notchHeight != currentPlacement?.notchHeight
            || placement.notchWidth != currentPlacement?.notchWidth
        currentPlacement = placement

        let displayID = NotchGeometry.displayID(of: screen)
        let changedDisplays = displayID != currentDisplayID
        currentDisplayID = displayID

        if panel.frame != placement.frame {
            panel.setFrame(placement.frame, display: true)
        }
        if notchChanged { updateRootView() }
        // The hit region is derived from the display, so it goes stale the
        // moment the island changes screens: a cutout-shaped region left behind
        // on a notchless monitor is an island that draws and then ignores the
        // pointer, which is what "it doesn't work over there" looks like.
        updateInteractiveRegion()
        applyIdlePresence()

        // Crossing displays is not reliably just a frame change. AppKit can
        // leave a window ordered into the screen it came from, so the island
        // lands on the new one invisible. Re-assert the order once the move has
        // been committed — a runloop hop later, because doing it in the same
        // pass is what fails.
        if changedDisplays, isShown {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isShown else { return }
                    self.panel.orderFrontRegardless()
                }
            }
        }
    }

    /// Watch the pointer while the island is set to follow the active display.
    ///
    /// There is no notification for "the active display changed". The two this
    /// class already listens to fire for display *configuration* changes and
    /// space switches, and neither of those happens when you simply move to the
    /// other monitor — so "Active display" resolved once at launch and then
    /// never again, which from the outside is indistinguishable from the
    /// setting doing nothing at all.
    ///
    /// A global monitor for mouse events needs no accessibility permission;
    /// only keyboard events do.
    private func followActiveDisplay(_ follow: Bool) {
        guard follow != (pointerMonitor != nil) else { return }
        if follow {
            pointerMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerMoved() }
            }
        } else if let pointerMonitor {
            NSEvent.removeMonitor(pointerMonitor)
            self.pointerMonitor = nil
        }
    }

    /// Move only when the pointer has actually crossed onto another display.
    ///
    /// Mouse moves arrive by the hundred a second; a window move does not need
    /// to. The rate limit bounds how often the screen list is walked, and the
    /// display comparison stops anything at all happening while the pointer
    /// wanders around the screen the island is already on.
    private func pointerMoved() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPointerCheck > 0.1 else { return }
        lastPointerCheck = now

        guard let screen = NotchGeometry.screen(for: screenPreference),
              NotchGeometry.displayID(of: screen) != currentDisplayID
        else { return }
        reposition()
    }

    /// Lid open/close and monitor sleep move the panel between displays mid-session.
    private func observeScreenChanges() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        })

        // A space switch can leave a stationary panel stranded on some setups.
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        })
    }
}
