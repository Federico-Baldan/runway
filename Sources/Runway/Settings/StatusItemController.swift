import AppKit
import SwiftUI

/// Tells the controller when its menu is on screen.
///
/// A separate object rather than the controller itself, because
/// `StatusItemController` is not an `NSObject` subclass and `NSMenuDelegate`
/// needs one. It holds nothing and forwards two events.
@MainActor
private final class MenuPresenceWatcher: NSObject, NSMenuDelegate {
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?

    func menuWillOpen(_ menu: NSMenu) { onOpen?() }

    func menuDidClose(_ menu: NSMenu) { onClose?() }
}

/// The menu bar status item — the app's permanent handle.
@MainActor
public final class StatusItemController {
    private let statusItem: NSStatusItem
    private let model: IslandModel
    private let onOpenSettings: () -> Void
    private let onRefresh: () -> Void
    private let onQuit: () -> Void

    private var lastMood: IslandMood?
    private var lastCount: Int = -1
    private var lastUpdate: String?
    /// Approvals move without the mood or the run count moving — a run going
    /// from "waiting on Alice" to "waiting on you" changes neither.
    private var lastApprovals: Int = -1
    /// And a run blocked on somebody *else*, which the count above cannot see.
    /// The summary line prints "N waiting for approval" off `blockedRuns`, so a
    /// second colleague's deploy reaching a gate moved that sentence while the
    /// mood stayed `.approval`, the run count stayed put, and the menu went on
    /// claiming there was one.
    private var lastBlocked: Int = -1
    /// So does the scope line. `rebuildMenu` prints how many repositories are
    /// watched and, on a failure, the error itself — and a repository list that
    /// grows on its five-minute refresh, or an error whose *text* changes while
    /// the mood stays `.error`, moves neither the mood nor the run count. The
    /// menu simply kept showing the old sentence.
    private var lastRepositoryCount: Int = -1
    private var lastError: String?
    /// And so does where the runs are going. A deploy target lands with the
    /// job detail, one request after the run itself, and moves neither the
    /// mood nor the count — so without this the row keeps the title it was
    /// built with before anybody knew where it was deploying.
    private var lastEnvironments: String?

    /// Whether the menu is currently on screen, and whether a redraw arrived
    /// while it was.
    ///
    /// `rebuildMenu` assigns a brand-new `NSMenu` to the status item, and doing
    /// that to an item whose menu is open closes it. A poll lands every five
    /// seconds while something is building, which is exactly when somebody is
    /// most likely to have the menu open reading it — so the menu shut itself
    /// mid-read, on a timer, and the click that reopened it started the same
    /// race again. Held back until the menu closes instead.
    private let menuWatcher = MenuPresenceWatcher()
    private var isMenuOpen = false
    private var needsMenuRebuild = false

    public init(
        model: IslandModel,
        onOpenSettings: @escaping () -> Void,
        onRefresh: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.model = model
        self.onOpenSettings = onOpenSettings
        self.onRefresh = onRefresh
        self.onQuit = onQuit

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton()
        menuWatcher.onOpen = { [weak self] in self?.isMenuOpen = true }
        menuWatcher.onClose = { [weak self] in
            guard let self else { return }
            isMenuOpen = false
            guard needsMenuRebuild else { return }
            needsMenuRebuild = false
            rebuildMenu()
        }
        rebuildMenu()
        // The only two things that change this item are the model — pushed in by
        // the app delegate through `refresh()` — and the once-a-day update check,
        // which now calls back rather than being polled for. It used to be a 1 Hz
        // loop that ran for the life of the process and rebuilt nothing on almost
        // every tick.
        UpdateCheck.checkIfDue { [weak self] _ in self?.redraw() }
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = Self.symbol(for: .idle)
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading
        button.toolTip = "Runway"
    }

    /// Every icon this item can draw, built once.
    ///
    /// There are seven of them — six moods and the no-token warning — and they
    /// never change. They were being rebuilt from scratch on demand, which
    /// `rebuildMenu` does up to thirteen times in a pass: once per approval row
    /// and once per run row, on top of the button's own. Each rebuild is either
    /// a fresh `NSImage` with a drawing handler (the brand mark) or an SF Symbol
    /// lookup plus two `SymbolConfiguration` allocations, and a poll rebuilds
    /// the menu every five seconds while something is building.
    ///
    /// Sharing one `NSImage` between menu items is fine — AppKit does not
    /// mutate them — and the brand mark is drawn through a handler rather than
    /// captured as a bitmap, so a cached instance still re-renders at whatever
    /// scale the display it lands on asks for.
    private static var symbolCache: [String: NSImage] = [:]

    /// Build the icon for a mood, or hand back the one already built.
    private static func symbol(for mood: IslandMood, hasToken: Bool = true) -> NSImage? {
        let key = hasToken ? "mood:\(mood.rank)" : "no-token"
        if let cached = symbolCache[key] { return cached }
        let image = makeSymbol(for: mood, hasToken: hasToken)
        if let image { symbolCache[key] = image }
        return image
    }

    private static func makeSymbol(for mood: IslandMood, hasToken: Bool) -> NSImage? {
        guard hasToken else {
            return tinted("exclamationmark.circle", .systemOrange, template: false)
        }
        switch mood {
        case .idle:
            // The one state with nothing to report is the one the mark gets to
            // hold: at rest the item is the brand, not a status glyph. Every
            // other case still speaks in SF Symbols, because those are saying
            // something and the mark is not.
            let image = BrandMark.statusItem()
            image.accessibilityDescription = "Runway — idle"
            return image
        case .approval:
            // The one menu bar state that is asking for something back.
            return tinted("exclamationmark.circle.fill", .systemOrange, template: false)
        case .running:
            return tinted("circle.dotted", .systemBlue, template: false)
        case .failed:
            return tinted("xmark.circle.fill", .systemRed, template: false)
        case .success:
            return tinted("checkmark.circle.fill", .systemGreen, template: false)
        case .error:
            return tinted("exclamationmark.circle", .systemOrange, template: false)
        }
    }

    private static func tinted(_ name: String, _ colour: NSColor, template: Bool) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: name) else {
            return nil
        }
        // Pinned to the same optical size as the brand mark rather than left at
        // whatever AppKit picks. The item swaps between the two on every state
        // change, and an icon that changes size when a run starts reads as the
        // app resizing itself.
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [colour]))
        let image = base.withSymbolConfiguration(config) ?? base
        image.isTemplate = template
        return image
    }

    // MARK: - Menu

    private func rebuildMenu() {
        // Never out from under an open menu — see `needsMenuRebuild`.
        guard !isMenuOpen else {
            needsMenuRebuild = true
            return
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = menuWatcher

        // Live summary line, disabled — a label rather than an action.
        let summary = NSMenuItem(title: summaryTitle(), action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)

        // Say which filter is in force, so an empty island is explicable
        // without opening Settings.
        let scopeItem = NSMenuItem(title: scopeTitle(), action: nil, keyEquivalent: "")
        scopeItem.isEnabled = false
        menu.addItem(scopeItem)

        // Anything waiting on this account, first and named as such. It is
        // the only entry in this menu that is worth opening a browser for
        // right now, so it does not get buried in the run list below.
        let awaiting = model.runsAwaitingMe
        if !awaiting.isEmpty {
            menu.addItem(.separator())
            for run in awaiting.prefix(5) {
                let environments = run.blockedEnvironmentLabel.map { " → \($0)" } ?? ""
                let item = NSMenuItem(
                    title: "Approve \(run.repositoryName) #\(run.runNumber)\(environments)…",
                    action: #selector(openRun(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = run
                item.image = Self.symbol(for: .approval)
                item.toolTip = "Opens the run on GitHub. Approving happens there — "
                    + "Runway's token is read-only by design."
                menu.addItem(item)
            }
        }

        // One entry per live run, click to open in the browser.
        let live = model.relevantRuns
        if !live.isEmpty {
            menu.addItem(.separator())
            for run in live.prefix(8) {
                var title = "\(run.repository) #\(run.runNumber) · \(run.headBranch ?? "—")"
                // The same arrow the approval rows above use, and for the same
                // reason: it is the destination, not another attribute of the
                // run.
                if let target = run.deployTarget {
                    title += " → \(target.name)"
                }
                if let login = run.triggeringActor?.login ?? run.actor?.login {
                    title += "  (\(login))"
                }
                let item = NSMenuItem(
                    title: title,
                    action: #selector(openRun(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = run
                item.image = Self.symbol(for: IslandModel.mood(for: run))
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        if let version = UpdateCheck.availableVersion {
            let update = NSMenuItem(
                title: "Update available: \(version)",
                action: #selector(openUpdate),
                keyEquivalent: ""
            )
            update.target = self
            update.image = NSImage(systemSymbolName: "arrow.down.circle.fill",
                                   accessibilityDescription: "Update available")
            menu.addItem(update)
            menu.addItem(.separator())
        }

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Runway", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func summaryTitle() -> String {
        if let error = model.state.error {
            return error
        }
        let live = model.relevantRuns
        guard !live.isEmpty else { return "Nothing running" }
        let mine = model.runsAwaitingMe.count
        let blocked = model.blockedRuns.count
        let running = live.filter { $0.isActive && !$0.isBlockedOnApproval }.count
        let failed = live.filter { $0.status.isFailure }.count
        var parts: [String] = []
        // Leads with the approval for the same reason the island does: it is
        // the only line here that is a request rather than a report.
        if mine > 0 { parts.append("\(mine) waiting on you") }
        else if blocked > 0 { parts.append("\(blocked) waiting for approval") }
        if running > 0 { parts.append("\(running) running") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.isEmpty ? "\(live.count) recent" : parts.joined(separator: ", ")
    }

    /// A one-line description of the current filter.
    private func scopeTitle() -> String {
        let preferences = Preferences.shared
        let repos = model.state.repositories.count
        let repoPart = repos == 0
            ? "no repositories"
            : "\(repos) repo\(repos == 1 ? "" : "s")"

        let filter = preferences.actorFilter
        let actorPart: String
        if filter.isEveryone {
            actorPart = "everyone"
        } else if filter.logins.count == 1, let only = filter.logins.first {
            actorPart = only
        } else {
            actorPart = "\(filter.logins.count) people"
        }
        return "Watching \(repoPart) · \(actorPart)"
    }

    // MARK: - Actions

    @objc private func openRun(_ sender: NSMenuItem) {
        guard let run = sender.representedObject as? WorkflowRun,
              let url = run.webURL() else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func refresh() { onRefresh() }
    @objc private func openUpdate() { UpdateCheck.openReleasePage() }
    @objc private func openSettings() { onOpenSettings() }
    @objc private func quit() { onQuit() }

    // MARK: - State

    /// Keep the icon and menu in step with the model.
    /// Redraw the item if anything it shows has actually moved.
    ///
    /// Named `redraw` rather than `refresh` because `refresh()` is already the
    /// @objc selector behind the "Refresh Now" menu item, which means something
    /// else entirely: go ask GitHub again.
    public func redraw() {
        let mood = model.mood
        let count = model.relevantRuns.count
        let update = UpdateCheck.availableVersion
        let approvals = model.runsAwaitingMe.count
        let blocked = model.blockedRuns.count
        let repositories = model.state.repositories.count
        let error = model.state.error
        let environments = model.relevantRuns
            .compactMap(\.deployTarget?.name)
            .joined(separator: ",")
        guard mood != lastMood || count != lastCount || update != lastUpdate
                || approvals != lastApprovals || blocked != lastBlocked
                || repositories != lastRepositoryCount
                || error != lastError || environments != lastEnvironments else { return }
        lastEnvironments = environments
        lastUpdate = update
        lastMood = mood
        lastCount = count
        lastApprovals = approvals
        lastBlocked = blocked
        lastRepositoryCount = repositories
        lastError = error

        if let button = statusItem.button {
            button.image = Self.symbol(for: mood, hasToken: TokenCache.shared.token() != nil)
            button.title = count > 1 ? " \(count)" : ""
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        }
        rebuildMenu()
    }

    public func invalidate() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}
