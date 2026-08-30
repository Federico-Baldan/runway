import AppKit
import SwiftUI

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
        rebuildMenu()
        // The only two things that change this item are the model — pushed in by
        // the app delegate through `refresh()` — and the once-a-day update check,
        // which now calls back rather than being polled for. It used to be a 1 Hz
        // loop that ran for the life of the process and rebuilt nothing on almost
        // every tick.
        UpdateCheck.checkIfDue { [weak self] _ in self?.refresh() }
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = Self.symbol(for: .idle)
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading
        button.toolTip = "Runway"
    }

    /// Build the icon for a mood.
    private static func symbol(for mood: IslandMood, hasToken: Bool = true) -> NSImage? {
        guard hasToken else {
            return tinted("exclamationmark.circle", .systemOrange, template: false)
        }
        switch mood {
        case .idle:
            let image = NSImage(
                systemSymbolName: "smallcircle.filled.circle",
                accessibilityDescription: "Runway — idle"
            )
            image?.isTemplate = true
            return image
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
        let config = NSImage.SymbolConfiguration(paletteColors: [colour])
        let image = base.withSymbolConfiguration(config) ?? base
        image.isTemplate = template
        return image
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Live summary line, disabled — a label rather than an action.
        let summary = NSMenuItem(title: summaryTitle(), action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)

        // Say which filter is in force, so an empty island is explicable
        // without opening Settings.
        let scopeItem = NSMenuItem(title: scopeTitle(), action: nil, keyEquivalent: "")
        scopeItem.isEnabled = false
        menu.addItem(scopeItem)

        // One entry per live run, click to open in the browser.
        let live = model.relevantRuns
        if !live.isEmpty {
            menu.addItem(.separator())
            for run in live.prefix(8) {
                var title = "\(run.repository) #\(run.runNumber) · \(run.headBranch ?? "—")"
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
                item.image = Self.symbol(for: IslandModel.mood(for: run.status))
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
        let running = live.filter(\.isActive).count
        let failed = live.filter { $0.status.isFailure }.count
        var parts: [String] = []
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
    public func refresh() {
        let mood = model.mood
        let count = model.relevantRuns.count
        let update = UpdateCheck.availableVersion
        guard mood != lastMood || count != lastCount || update != lastUpdate else { return }
        lastUpdate = update
        lastMood = mood
        lastCount = count

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
