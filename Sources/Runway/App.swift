import AppKit
import SwiftUI

/// Application entry point.
@main
enum RunwayApp {
    /// The delegate, held for the life of the process — see `launchUI`.
    @MainActor private static var retainedDelegate: AppDelegate?

    @MainActor
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)

        let arguments = CommandLine.arguments
        let command = arguments.count > 1 ? arguments[1] : "run"

        switch command {
        case "store", "delete", "verify", "migrate":
            CommandLineHarness.run(command: command, arguments: arguments)
        case "run":
            launchUI()
        case "--diagnose":
            Diagnostics.run()
            exit(0)
        case "--login-status":
            // Report SMAppService state, for verifying launch-at-login works
            // from inside a real bundle.
            LaunchAtLogin.printStatus()
            exit(0)
        case "--demo-notch":
            NotchGeometry.simulateNotch = true
            launchUI(demo: true)
        case "--demo":
            launchUI(demo: true)
        case "--snapshot":
            launchUI(snapshotPath: arguments.count > 2 ? arguments[2] : "island.png")
        case "--snapshot-notch":
            NotchGeometry.simulateNotch = true
            launchUI(snapshotPath: arguments.count > 2 ? arguments[2] : "island-notch.png",
                     snapshotNotch: true)
        case "--snapshot-fail":
            launchUI(snapshotPath: arguments.count > 2 ? arguments[2] : "island-fail.png",
                     snapshotFailure: true)
        case "--verify-ui":
            launchUI(verifyOnly: true)
        default:
            print("""
            usage: Runway [run | --demo | --demo-notch | --verify-ui | --diagnose
                          | --login-status | --snapshot <path> | --snapshot-notch <path>
                          | --snapshot-fail <path>
                          | store <TOKEN> | migrate | delete | verify]
            """)
            exit(1)
        }
    }

    @MainActor
    private static func launchUI(
        verifyOnly: Bool = false,
        snapshotPath: String? = nil,
        demo: Bool = false,
        snapshotFailure: Bool = false,
        snapshotNotch: Bool = false
    ) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let delegate = AppDelegate(
            verifyOnly: verifyOnly,
            snapshotPath: snapshotPath,
            demo: demo,
            snapshotFailure: snapshotFailure,
            snapshotNotch: snapshotNotch
        )
        // `NSApplication.delegate` is a *weak* reference, which leaves this
        // local as the only strong one — and ARC is free to release a local
        // straight after its last use, which is the assignment below. A release
        // build is entitled to deallocate the delegate before `run()` ever
        // calls it, and Homebrew installs release builds. Hold it explicitly.
        retainedDelegate = delegate
        app.delegate = delegate
        app.run()
    }
}

/// Owns the monitor, the model and the panel for the lifetime of the process.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = IslandModel()
    private let monitor = RunMonitor(
        client: GitHubClient(baseURL: GitHubClient.baseURL(for: Preferences.shared.host))
    )
    private var panelController: NotchPanelController?

    private var streamTask: Task<Void, Never>?
    private var demoTask: Task<Void, Never>?

    /// Notification tokens for the observers that replaced the old poll loops.
    ///
    /// Kept per centre. A token only unregisters from the centre that issued
    /// it, so one shared array meant every removal was half a no-op — harmless
    /// today only because the app is exiting when it runs.
    private var defaultCenterObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Last-seen preference values, so a change notification for an unrelated
    /// key does not reconfigure the monitor.
    private var lastScreenPreference: NotchGeometry.ScreenPreference?
    private var lastPinnedDisplay: Int?
    private var lastDrawnNotch: Bool?
    private var lastIdleMark: Bool?
    private var lastIdleMarkPosition: IdleMarkPosition?
    private var lastIdleMarkTint: IdleMarkTint?
    private var lastConfigurationSignature: String?
    private var lastHost: String?
    /// Debounce for the host field — see `hostChanged`.
    private var hostChangeTask: Task<Void, Never>?

    private let verifyOnly: Bool
    private let snapshotPath: String?
    private let demo: Bool
    private let snapshotFailure: Bool
    private let snapshotNotch: Bool

    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindowController?

    init(
        verifyOnly: Bool,
        snapshotPath: String?,
        demo: Bool = false,
        snapshotFailure: Bool = false,
        snapshotNotch: Bool = false
    ) {
        self.verifyOnly = verifyOnly
        self.snapshotPath = snapshotPath
        self.demo = demo
        self.snapshotFailure = snapshotFailure
        self.snapshotNotch = snapshotNotch
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = NotchPanelController(
            model: model,
            onOpen: { [weak self] run in self?.open(run) },
            onDismiss: { [weak self] run in self?.dismiss(run) },
            onQuit: { NSApplication.shared.terminate(nil) }
        )
        panelController = controller
        // Before the preference, not after: the preference is what makes the
        // island move, and it must not move to whatever was pinned last time
        // on its way to the display that is actually pinned now.
        NotchGeometry.pinnedDisplayID = Self.pinnedDisplayID()
        // Also before the preference: it changes what every screen measures as,
        // so the first placement must already know the answer.
        NotchGeometry.drawsNotchOnNotchlessDisplays = Preferences.shared.drawnNotch
        controller.screenPreference = Preferences.shared.screenPreference
        controller.showsIdleMark = Preferences.shared.idleMark
        controller.idleMarkPosition = Preferences.shared.idleMarkPosition
        controller.idleMarkTint = Preferences.shared.idleMarkTint

        if verifyOnly {
            runVerification(controller)
            return
        }

        if let snapshotPath {
            runSnapshot(to: snapshotPath)
            return
        }

        settingsWindow = SettingsWindowController(
            model: model,
            onTokenChanged: { [weak self] in
                TokenCache.shared.invalidate()
                Haptics.resetBaseline()
                // A different account has a different idea of what is waiting
                // on it, so the "already told you about this" record goes too.
                ApprovalNotifier.resetBaseline()
                self?.resetForNewToken()
            },
            onRestoreDismissed: { [weak self] in self?.restoreDismissed() }
        )
        Haptics.isEnabled = Preferences.shared.haptics
        ApprovalNotifier.isEnabled = Preferences.shared.approvalNotifications
        // Installs the click handler and reads the current permission. It does
        // not ask for one — see `ApprovalNotifier.prepare`.
        ApprovalNotifier.prepare()
        statusItem = StatusItemController(
            model: model,
            onOpenSettings: { [weak self] in self?.settingsWindow?.show() },
            onRefresh: { [weak self] in self?.refreshNow() },
            onQuit: { NSApplication.shared.terminate(nil) }
        )

        if demo {
            // Scripted local data only — no monitor, no network, no keychain.
            print("demo mode: scripted runs, no GitHub calls")
            TokenCache.shared.isDisabled = true
            // The demo script includes a run parked on an approval, and a
            // banner about a repository that does not exist is not a demo.
            ApprovalNotifier.isEnabled = false
            demoTask = DemoData.run(model: model)
            observeModelForLayout()
            return
        }

        startMonitoring()
        observeModelForLayout()
        observeAppLifecycle()
        observePreferences()
    }

    /// Push the configured scopes into the monitor.
    private func applyConfiguration() {
        let monitor = self.monitor
        let preferences = Preferences.shared
        let repoScope = preferences.repoScope
        let repoLimit = preferences.repoLimit
        let organizations = preferences.organizations
        let explicit = preferences.explicitRepositories
        let actorScope = preferences.actorScope
        let watchedActors = preferences.watchedActors
        let approvalsFromOthers = preferences.approvalsFromOthers
        let currentUser = preferences.currentUser

        Task.detached {
            await monitor.configure(
                repoScope: repoScope,
                repoLimit: repoLimit,
                organizations: organizations,
                explicitRepositories: explicit,
                actorScope: actorScope,
                watchedActors: watchedActors,
                approvalsFromOthers: approvalsFromOthers,
                currentUser: currentUser
            )
        }
    }

    /// Point the monitor at a different GitHub instance.
    ///
    /// Debounced, because the Host field in Settings writes to `UserDefaults` on
    /// every keystroke and a host change is a full reset with a poll behind it:
    /// typing `ghe.example.com` unthrottled is eighteen resets and eighteen
    /// round trips to hosts that mostly do not exist. It waits for the typing to
    /// stop instead.
    ///
    /// Not folded into `configurationSignature`: that one describes what to
    /// watch, and is applied immediately and cheaply. This throws every cache
    /// away.
    private func hostChanged(to host: String) {
        hostChangeTask?.cancel()
        hostChangeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, let self else { return }
            let monitor = self.monitor
            let url = GitHubClient.baseURL(for: host)
            // A different instance is a different world: `setBaseURL` throws
            // every run away and the next poll repopulates from nothing, so
            // every run it finds looks new. See `applyChangedPreferences`.
            Haptics.resetBaseline()
            Task.detached {
                await monitor.setBaseURL(url)
                await monitor.refreshNow()
            }
        }
    }

    /// The pinned display as a `CGDirectDisplayID`, or nil when none is set.
    private static func pinnedDisplayID() -> CGDirectDisplayID? {
        let stored = Preferences.shared.pinnedDisplay
        return stored > 0 ? CGDirectDisplayID(stored) : nil
    }

    /// Force an immediate poll — used by "Refresh Now".
    private func refreshNow() {
        let monitor = self.monitor
        Task.detached { await monitor.refreshNow() }
    }

    /// A new token invalidates every token-scoped cache, ETags included.
    private func resetForNewToken() {
        let monitor = self.monitor
        Task.detached {
            await monitor.resetForNewToken()
            await monitor.refreshNow()
        }
    }

    /// Push preference changes into the parts of the app that read them.
    private func observePreferences() {
        lastHost = Preferences.shared.host
        lastScreenPreference = Preferences.shared.screenPreference
        lastPinnedDisplay = Preferences.shared.pinnedDisplay
        lastDrawnNotch = Preferences.shared.drawnNotch
        lastIdleMark = Preferences.shared.idleMark
        lastIdleMarkPosition = Preferences.shared.idleMarkPosition
        lastIdleMarkTint = Preferences.shared.idleMarkTint
        lastConfigurationSignature = configurationSignature()

        // Push the stored configuration in immediately, before the first poll.
        applyConfiguration()

        // Preferences change when the user changes them, not when time passes,
        // so this listens instead of polling once a second forever. The
        // signature diff is kept because `didChangeNotification` fires for every
        // key in the domain, including ones the monitor does not care about.
        defaultCenterObservers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyChangedPreferences() }
        })
    }

    /// Apply whichever preferences actually moved.
    private func applyChangedPreferences() {
        let host = Preferences.shared.host
        if host != lastHost {
            lastHost = host
            hostChanged(to: host)
        }

        // Ahead of the screen preference, for the reason given where it is
        // first pushed in: a stale pinned ID would send the island to the wrong
        // display for as long as it took the next line to run.
        let pinned = Preferences.shared.pinnedDisplay
        if pinned != lastPinnedDisplay {
            lastPinnedDisplay = pinned
            NotchGeometry.pinnedDisplayID = Self.pinnedDisplayID()
            panelController?.reposition()
        }

        let drawnNotch = Preferences.shared.drawnNotch
        if drawnNotch != lastDrawnNotch {
            lastDrawnNotch = drawnNotch
            NotchGeometry.drawsNotchOnNotchlessDisplays = drawnNotch
            // Not just a redraw: it changes the band, the width, and whether
            // the panel hangs from the top of the screen or floats below the
            // menu bar, so the whole placement has to be taken again.
            panelController?.reposition()
        }

        let screen = Preferences.shared.screenPreference
        if screen != lastScreenPreference {
            lastScreenPreference = screen
            panelController?.screenPreference = screen
        }

        let idleMark = Preferences.shared.idleMark
        if idleMark != lastIdleMark {
            lastIdleMark = idleMark
            panelController?.showsIdleMark = idleMark
        }

        let idleMarkPosition = Preferences.shared.idleMarkPosition
        if idleMarkPosition != lastIdleMarkPosition {
            lastIdleMarkPosition = idleMarkPosition
            panelController?.idleMarkPosition = idleMarkPosition
        }

        let idleMarkTint = Preferences.shared.idleMarkTint
        if idleMarkTint != lastIdleMarkTint {
            lastIdleMarkTint = idleMarkTint
            panelController?.idleMarkTint = idleMarkTint
        }

        let signature = configurationSignature()
        if signature != lastConfigurationSignature {
            lastConfigurationSignature = signature
            // Before the reconfigure, not after: `configure(_:)` re-derives what
            // is on screen and emits immediately, and that emit is what reaches
            // `Haptics`.
            //
            // `Haptics` infers "a run started" from a run it has not seen
            // before, which is right when a poll brings one back and wrong
            // every time the *filter* moves underneath it. Narrowing "Whose
            // runs" drops a colleague's build out of `lastStatus`; widening it
            // again puts the same build back looking exactly like a new one,
            // and the tap that follows announces something that started twenty
            // minutes ago. The same is true of every scope here — changing the
            // repository list re-derives the visible set without anything
            // having happened on GitHub at all.
            //
            // The same trade the token path already makes two screens up, for
            // the same reason: a lost baseline costs the next poll's taps, and
            // that is the right price for never inventing one. Anything
            // genuinely starting is one cadence away.
            Haptics.resetBaseline()
            applyConfiguration()
        }
    }

    /// Everything the monitor needs to be told about, as one comparable string.
    ///
    /// Cheaper and less error-prone than tracking seven `last…` variables, which
    /// is what the field-by-field version degenerated into.
    private func configurationSignature() -> String {
        let preferences = Preferences.shared
        return [
            preferences.repoScope.rawValue,
            "\(preferences.repoLimit)",
            preferences.organizations.sorted().joined(separator: ","),
            preferences.explicitRepositories.joined(separator: ","),
            preferences.actorScope.rawValue,
            preferences.watchedActors.joined(separator: ","),
            preferences.approvalsFromOthers ? "approvals" : "strict",
            preferences.currentUser ?? "",
        ].joined(separator: "|")
    }

    func applicationWillTerminate(_ notification: Notification) {
        streamTask?.cancel()
        demoTask?.cancel()
        hostChangeTask?.cancel()
        for observer in defaultCenterObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        defaultCenterObservers.removeAll()
        workspaceObservers.removeAll()
        model.onDisplayChange = nil
        statusItem?.invalidate()
        panelController?.invalidate()
    }

    // MARK: - Monitor wiring

    /// Subscribe first, then start.
    private func startMonitoring() {
        let monitor = self.monitor
        let model = self.model
        // Read here, on the main actor, and handed across — so the ordering
        // below is the only ordering that has to hold.
        let dismissed = DismissedRuns.load()

        streamTask = Task.detached {
            // Subscribe before starting, so the first poll's result cannot land
            // before there is anything listening for it.
            let stream = await monitor.stateStream()
            // And adopt the dismissals before `start()`, in this same task
            // rather than a second detached one: two tasks racing into the same
            // actor have no order, and the one that loses puts a run the user
            // hid yesterday back on the island for a frame this morning.
            await monitor.adoptDismissed(dismissed) { identities in
                // Hopped rather than written where it is called: this closure
                // runs on the monitor's executor, and the store is main-actor
                // work. Fire and forget — nothing waits on a preference write.
                Task { @MainActor in DismissedRuns.save(identities) }
            }
            // `start()` spawns the loop and returns; it does not block, which
            // is why the task that used to wrap it had always finished long
            // before the `cancel()` that followed this loop.
            await monitor.start()

            for await state in stream {
                await MainActor.run { model.apply(state) }
            }
        }
    }

    /// Keep the panel in sync with the model's derived visibility.
    ///
    /// This used to be a 2 Hz poll that ran forever. Nothing about the island
    /// changes on a clock the app does not already own: the panel's visibility
    /// moves when a new monitor state arrives, when a finished run ages out of
    /// its linger window (the model's 1 s ticker, which only runs while there
    /// are runs to age), and when the hover expansion toggles. All three now
    /// call in, so an idle Runway schedules no wakeups of its own at all.
    private func observeModelForLayout() {
        model.onDisplayChange = { [weak self] in self?.syncUI() }
        panelController?.onExpansionChange = { [weak self] in self?.syncUI() }
        syncUI()
    }

    /// Push the model's current shape into both surfaces that draw it.
    ///
    /// Both used to keep their own poll loop — the panel at 2 Hz, the status
    /// item at 1 Hz — for state that only ever changes here. Each does its own
    /// cheap no-change check, so calling them on every model event is less work
    /// than either loop was doing while idle.
    private func syncUI() {
        statusItem?.redraw()
        guard let controller = panelController else { return }
        controller.refreshInteractiveRegion()
        controller.setVisible(model.isVisible)
    }

    /// Slow the poll cadence down when the machine is not being looked at.
    ///
    /// Two separate signals, because they are not the same event. The display
    /// going dark means nobody can see the island; the machine going to sleep
    /// means the loop should not be the thing that keeps waking it. A lid close
    /// raises both, but a Mac told to sleep from the menu raises only the second
    /// and an idle display timeout only the first.
    private func observeAppLifecycle() {
        let workspace = NSWorkspace.shared.notificationCenter

        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            workspaceObservers.append(workspace.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self, monitor] _ in
                MainActor.assumeIsolated { self?.model.setSuspended(true) }
                Task.detached { await monitor.setSuspended(true) }
            })
        }

        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(workspace.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self, monitor] _ in
                MainActor.assumeIsolated { self?.model.setSuspended(false) }
                Task.detached {
                    await monitor.setSuspended(false)
                    await monitor.refreshNow()
                }
            })
        }

        // Low Power Mode is the user saying, in the system's own words, spend
        // less battery. A CI watcher that keeps polling every 5 seconds through
        // it is ignoring a direct instruction.
        defaultCenterObservers.append(NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object: nil, queue: .main
        ) { [monitor] _ in
            let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            Task.detached { await monitor.setLowPower(lowPower) }
        })

        let lowPowerNow = ProcessInfo.processInfo.isLowPowerModeEnabled
        Task.detached { [monitor] in await monitor.setLowPower(lowPowerNow) }
    }

    // MARK: - Actions

    private func open(_ run: WorkflowRun) {
        guard let url = run.webURL() else { return }
        NSWorkspace.shared.open(url)
    }

    /// Take one run off the island, and remember that across launches.
    ///
    /// Local. Nothing is sent to GitHub — see `DismissedRuns` for why that is
    /// the design and not a shortfall.
    private func dismiss(_ run: WorkflowRun) {
        let monitor = self.monitor
        let identity = run.identity
        Task.detached { await monitor.dismiss(identity) }
    }

    /// Restore every dismissed run. Wired to the Settings button.
    private func restoreDismissed() {
        let monitor = self.monitor
        // The third way the visible set moves without GitHub moving: a run the
        // user hid is not in `Haptics`' history either, so bringing it back
        // reads as it starting. See `applyChangedPreferences`.
        Haptics.resetBaseline()
        Task.detached { await monitor.restoreDismissed() }
    }



    // MARK: - Snapshots

    /// Render both island states offscreen to a PNG for review.
    private func runSnapshot(to path: String) {
        Task { @MainActor in
            model.apply(DemoData.concurrentState(tick: 1, withFailure: snapshotFailure))
            self.writeSnapshot(to: path)
        }
    }

    @MainActor
    private func writeSnapshot(to path: String) {
        let restWidth: CGFloat = snapshotNotch ? 190 : 520
        let collapsed = Self.render(model: model, width: restWidth, hasNotch: snapshotNotch)
        model.isExpanded = true
        let expanded = Self.render(model: model, width: 620, hasNotch: snapshotNotch)

        guard let image = Self.stack([collapsed, expanded].compactMap { $0 }),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("snapshot: render failed")
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("snapshot written: \(path) (\(Int(image.size.width))x\(Int(image.size.height)))")
            print("runs=\(model.state.runs.count) live=\(model.relevantRuns.count) mood=\(model.mood)")
            exit(0)
        } catch {
            print("snapshot: write failed \(error)")
            exit(1)
        }
    }

    /// Rasterise the island view at a fixed width.
    private static func render(model: IslandModel, width: CGFloat, hasNotch: Bool) -> NSImage? {
        model.isOnScreen = true

        let view = IslandView(
            model: model,
            hasNotch: hasNotch,
            notchHeight: hasNotch ? 32 : 0,
            notchWidth: hasNotch ? 190 : 0,
            onOpen: { _ in },
            onQuit: {}
        )
        let host = NSHostingView(rootView: AnyView(view))
        let height = host.fittingSize.height > 0 ? host.fittingSize.height : 320
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// Stack renders vertically on a neutral ground so both states are visible.
    private static func stack(_ images: [NSImage]) -> NSImage? {
        guard !images.isEmpty else { return nil }
        let pad: CGFloat = 16
        let width = images.map(\.size.width).max() ?? 0
        let height = images.reduce(0) { $0 + $1.size.height } + pad * CGFloat(images.count + 1)
        let canvas = NSImage(size: CGSize(width: width + pad * 2, height: height))
        canvas.lockFocus()
        NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
        CGRect(origin: .zero, size: canvas.size).fill()
        var y = height - pad
        for image in images {
            y -= image.size.height
            image.draw(at: CGPoint(x: pad, y: y), from: .zero, operation: .sourceOver, fraction: 1)
            y -= pad
        }
        canvas.unlockFocus()
        return canvas
    }

    // MARK: - Verification

    /// Prove a real window exists with non-zero bounds, then exit.
    private func runVerification(_ controller: NotchPanelController) {
        model.apply(DemoData.concurrentState(tick: 1))
        controller.reposition()
        controller.setVisible(true)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)

            let frame = controller.frame
            let placement = controller.placement

            print("── panel verification ──")
            print("screen:        \(placement?.screenName ?? "?")  \(Int(placement?.screenFrame.width ?? 0))x\(Int(placement?.screenFrame.height ?? 0))")
            print("hasNotch:      \(placement?.hasNotch ?? false)  notchWidth: \(Int(placement?.notchWidth ?? 0))")
            print("panel frame:   x=\(Int(frame.origin.x)) y=\(Int(frame.origin.y)) w=\(Int(frame.width)) h=\(Int(frame.height))")
            print("panel visible: \(controller.isVisible)")

            let onScreen = frame.width > 0 && frame.height > 0 && controller.isVisible
            print(onScreen ? "RESULT: PASS — window on screen with non-zero bounds"
                           : "RESULT: FAIL — no window with non-zero bounds")
            exit(onScreen ? 0 : 1)
        }
    }
}

// MARK: - CLI harness

/// The pre-UI command surface, kept so a token can be provisioned headlessly.
enum CommandLineHarness {
    static func run(command: String, arguments: [String]) {
        switch command {
        case "store":
            guard arguments.count > 2 else {
                print("usage: Runway store <TOKEN>")
                exit(1)
            }
            do {
                // The token is never printed, logged, or written to disk.
                try Keychain.store(arguments[2])
                print("token stored in Keychain (service \(Keychain.service), account \(Keychain.account))")
                if let kind = Keychain.describe(arguments[2]) {
                    print("looks like a \(kind)")
                }
            } catch {
                print("keychain write failed: \(error.localizedDescription)")
                exit(1)
            }

        case "migrate":
            if Keychain.migrateLegacyItem() {
                print("token migrated to the data-protection keychain")
            } else if TokenCache.shared.token() != nil {
                print("token already in the data-protection keychain — nothing to do")
            } else {
                print("no legacy token found. Run: Runway store <TOKEN>")
                exit(1)
            }

        case "delete":
            do {
                try Keychain.delete()
                print("token deleted")
            } catch {
                print("keychain delete failed: \(error.localizedDescription)")
                exit(1)
            }

        case "verify":
            Task {
                let code = await verifyToken()
                exit(code)
            }
            RunLoop.main.run()

        default:
            exit(1)
        }
    }

    private static func verifyToken() async -> Int32 {
        guard TokenCache.shared.token() != nil else {
            print("No token in Keychain. Run: Runway store <TOKEN>")
            return 1
        }
        let host = await MainActor.run { Preferences.shared.host }
        let client = GitHubClient(baseURL: GitHubClient.baseURL(for: host))
        do {
            let user = try await client.fetchAuthenticatedUser()
            print("token OK — authenticated as \(user.login)")

            let repositories = try await client.fetchRepositories(
                scope: .recent, limit: 10, organizations: [], explicit: []
            )
            print("\(repositories.count) repositories by recent push:")

            var totalRuns = 0
            var activeRuns = 0
            for repository in repositories.prefix(5) {
                let response = try await client.fetchRuns(
                    repository: repository.fullName, perPage: 5
                )
                let runs = response.value.workflowRuns
                totalRuns += runs.count
                activeRuns += runs.filter(\.isActive).count
                let logins = Set(runs.flatMap(\.logins)).sorted().joined(separator: ", ")
                print("  \(repository.fullName): \(runs.count) runs"
                    + (logins.isEmpty ? "" : "  [\(logins)]")
                    + (response.notModified ? "  (304, free)" : ""))
            }
            print("\(totalRuns) runs, \(activeRuns) active")

            let rate = await client.currentRateLimit()
            print("rate limit: \(rate.remaining)/\(rate.limit) left, resets in \(rate.resetDescription)")
            return 0
        } catch {
            let message = (error as? GitHubError)?.errorDescription ?? error.localizedDescription
            print("FAILED: \(message)")
            return 1
        }
    }
}
