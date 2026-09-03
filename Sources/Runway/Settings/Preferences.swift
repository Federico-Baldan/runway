import Foundation
import SwiftUI

/// Environment variables that seed the defaults.
///
/// The settings that decide *whose* runs appear are the ones people most want
/// to set from outside the UI — per project, per checkout, from a dotfile.
///
/// They are **defaults, not locks.** A variable supplies the starting value for
/// a setting the user has never touched; once it is changed in Settings, the
/// stored choice wins and the variable stops applying to it. An earlier version
/// let the environment override the UI permanently and greyed the controls out,
/// which meant a stray variable in a shell profile left you unable to change
/// your own settings from the app — with no way to fix it from the app either.
///
/// Settings still *says* when a variable is set, and offers a one-click reset
/// back to its value, so nothing about the behaviour is hidden.
///
/// The practical caveat: an `LSUIElement` app launched from Finder or as a
/// login item does not inherit your shell environment, so these apply when
/// Runway is started from a terminal (`make run`) or a launch agent. Since they
/// only seed first-run defaults, that matters much less than it used to.
public enum EnvironmentDefault {
    public static let actorMode = "RUNWAY_ACTOR_MODE"
    public static let actors = "RUNWAY_ACTORS"
    public static let repoScope = "RUNWAY_REPO_SCOPE"
    public static let repositories = "RUNWAY_REPOS"
    public static let repoLimit = "RUNWAY_REPO_LIMIT"
    public static let organizations = "RUNWAY_ORGS"
    public static let host = "RUNWAY_HOST"
    public static let notifyApprovals = "RUNWAY_NOTIFY_APPROVALS"
    public static let approvalsFromOthers = "RUNWAY_APPROVALS_FROM_OTHERS"

    /// Every variable Runway reads, for `--diagnose` and the README.
    public static let all = [
        actorMode, actors, repoScope, repositories, repoLimit, organizations, host,
        notifyApprovals, approvalsFromOthers,
    ]

    static func string(_ name: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func int(_ name: String) -> Int? {
        guard let raw = string(name) else { return nil }
        return Int(raw)
    }

    /// A flag, written the way people actually write flags in a shell profile.
    /// Anything unrecognised is treated as unset rather than as `false`, so a
    /// typo does not silently turn a feature off.
    static func bool(_ name: String) -> Bool? {
        guard let raw = string(name)?.lowercased() else { return nil }
        switch raw {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }

    /// Comma- or space-separated list, e.g. `RUNWAY_ACTORS="@me, alice, bob"`.
    static func list(_ name: String) -> [String]? {
        guard let raw = string(name) else { return nil }
        let parts = raw
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts
    }

    /// Is this setting currently pinned by the environment?
    public static func isSet(_ name: String) -> Bool { string(name) != nil }
}

/// User-facing settings, persisted in `UserDefaults`.
@MainActor
@Observable
public final class Preferences {
    public static let shared = Preferences()

    private enum Key {
        static let host = "github.host"
        static let screenPreference = "island.screen"
        static let repoScope = "repos.scope"
        static let repoLimit = "repos.limit"
        static let organizations = "repos.organizations"
        static let explicitRepositories = "repos.explicit"
        static let actorScope = "actors.scope"
        static let watchedActors = "actors.watched"
        static let currentUser = "account.login"
        static let haptics = "island.haptics"
        static let idleMark = "island.idleMark"
        static let idleMarkPosition = "island.idleMarkPosition"
        static let approvalNotifications = "notify.approvals"
        static let approvalsFromOthers = "actors.approvalsFromOthers"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Each setting: the stored choice if the user has ever made one,
        // otherwise the environment, otherwise the built-in default. Reading
        // in that order is what makes the variables defaults rather than locks.
        func stored(_ key: String) -> Bool { defaults.object(forKey: key) != nil }

        self.host = defaults.string(forKey: Key.host)
            ?? EnvironmentDefault.string(EnvironmentDefault.host)
            ?? "https://github.com"

        self.screenPreference = NotchGeometry.ScreenPreference(
            rawValue: defaults.string(forKey: Key.screenPreference) ?? ""
        ) ?? .primary

        self.repoScope = RepoScope(rawValue: defaults.string(forKey: Key.repoScope) ?? "")
            ?? EnvironmentDefault.string(EnvironmentDefault.repoScope).flatMap(RepoScope.init(rawValue:))
            ?? .recent

        // Clamped to the range the Stepper in Settings offers, because the
        // environment is not the Stepper: `RUNWAY_REPO_LIMIT=0` resolved to
        // "poll no repositories at all", and an island that never appears
        // because it was told to watch nothing is indistinguishable from one
        // that is broken.
        self.repoLimit = min(max((defaults.object(forKey: Key.repoLimit) as? Int)
            ?? EnvironmentDefault.int(EnvironmentDefault.repoLimit)
            ?? 20, 1), 100)

        self.organizations = Set(
            defaults.stringArray(forKey: Key.organizations)
                ?? EnvironmentDefault.list(EnvironmentDefault.organizations)
                ?? []
        )

        self.explicitRepositories = defaults.stringArray(forKey: Key.explicitRepositories)
            ?? EnvironmentDefault.list(EnvironmentDefault.repositories)
            ?? []

        self.actorScope = ActorScope(rawValue: defaults.string(forKey: Key.actorScope) ?? "")
            ?? EnvironmentDefault.string(EnvironmentDefault.actorMode).flatMap(ActorScope.init(rawValue:))
            ?? .me

        self.watchedActors = defaults.stringArray(forKey: Key.watchedActors)
            ?? EnvironmentDefault.list(EnvironmentDefault.actors)
            ?? [ActorFilter.selfToken]

        self.currentUser = defaults.string(forKey: Key.currentUser)
        self.haptics = defaults.object(forKey: Key.haptics) as? Bool ?? true
        self.idleMark = defaults.object(forKey: Key.idleMark) as? Bool ?? true
        self.idleMarkPosition = IdleMarkPosition(
            rawValue: defaults.string(forKey: Key.idleMarkPosition) ?? ""
        ) ?? .center
        self.approvalNotifications = (defaults.object(forKey: Key.approvalNotifications) as? Bool)
            ?? EnvironmentDefault.bool(EnvironmentDefault.notifyApprovals)
            ?? true
        self.approvalsFromOthers = (defaults.object(forKey: Key.approvalsFromOthers) as? Bool)
            ?? EnvironmentDefault.bool(EnvironmentDefault.approvalsFromOthers)
            ?? false

        // `RUNWAY_ACTORS` without `RUNWAY_ACTOR_MODE` reads as "watch these
        // people" — taking the list but leaving the mode on `.me` would ignore
        // it. Only applies while the user has not chosen a mode themselves.
        if EnvironmentDefault.isSet(EnvironmentDefault.actors),
           !EnvironmentDefault.isSet(EnvironmentDefault.actorMode),
           !stored(Key.actorScope) {
            self.actorScope = .list
        }
        // Same reasoning for an explicit repository list.
        if EnvironmentDefault.isSet(EnvironmentDefault.repositories),
           !EnvironmentDefault.isSet(EnvironmentDefault.repoScope),
           !stored(Key.repoScope) {
            self.repoScope = .explicit
        }
    }

    /// Put a setting back to what the environment says, for the reset button.
    public func resetToEnvironment(_ name: String) {
        switch name {
        case EnvironmentDefault.actorMode:
            if let value = EnvironmentDefault.string(name).flatMap(ActorScope.init(rawValue:)) {
                actorScope = value
            }
        case EnvironmentDefault.actors:
            if let value = EnvironmentDefault.list(name) { watchedActors = value }
        case EnvironmentDefault.repoScope:
            if let value = EnvironmentDefault.string(name).flatMap(RepoScope.init(rawValue:)) {
                repoScope = value
            }
        case EnvironmentDefault.repositories:
            if let value = EnvironmentDefault.list(name) { explicitRepositories = value }
        case EnvironmentDefault.repoLimit:
            if let value = EnvironmentDefault.int(name) { repoLimit = min(max(value, 1), 100) }
        case EnvironmentDefault.organizations:
            if let value = EnvironmentDefault.list(name) { organizations = Set(value) }
        case EnvironmentDefault.host:
            if let value = EnvironmentDefault.string(name) { host = value }
        case EnvironmentDefault.notifyApprovals:
            if let value = EnvironmentDefault.bool(name) { approvalNotifications = value }
        case EnvironmentDefault.approvalsFromOthers:
            if let value = EnvironmentDefault.bool(name) { approvalsFromOthers = value }
        default:
            break
        }
    }

    /// GitHub instance. Enterprise Server installs point this at their host.
    public var host: String {
        didSet { defaults.set(host, forKey: Key.host) }
    }

    /// Which display the island renders on.
    public var screenPreference: NotchGeometry.ScreenPreference {
        didSet { defaults.set(screenPreference.rawValue, forKey: Key.screenPreference) }
    }

    /// Which repositories are watched.
    public var repoScope: RepoScope {
        didSet { defaults.set(repoScope.rawValue, forKey: Key.repoScope) }
    }

    /// How many repositories to poll. The rate-limit dial.
    public var repoLimit: Int {
        didSet { defaults.set(repoLimit, forKey: Key.repoLimit) }
    }

    /// Organization logins selected when `repoScope == .organizations`.
    public var organizations: Set<String> {
        didSet { defaults.set(Array(organizations).sorted(), forKey: Key.organizations) }
    }

    /// `owner/repo` entries used when `repoScope == .explicit`.
    public var explicitRepositories: [String] {
        didSet { defaults.set(explicitRepositories, forKey: Key.explicitRepositories) }
    }

    /// Whose runs to show.
    public var actorScope: ActorScope {
        didSet { defaults.set(actorScope.rawValue, forKey: Key.actorScope) }
    }

    /// Logins watched when `actorScope == .list`. `@me` resolves at runtime.
    public var watchedActors: [String] {
        didSet { defaults.set(watchedActors, forKey: Key.watchedActors) }
    }

    /// The signed-in login, learned from `GET /user`.
    public var currentUser: String? {
        didSet { defaults.set(currentUser, forKey: Key.currentUser) }
    }

    /// Keep a few points of island under the cutout when nothing is running,
    /// with the mark in it.
    ///
    /// On by default, and only ever honoured on a display that has a cutout —
    /// `NotchPanelController` is what enforces that. `IdleMark` carries the
    /// argument for both halves.
    public var idleMark: Bool {
        didSet { defaults.set(idleMark, forKey: Key.idleMark) }
    }

    /// Where that mark sits in the band under the cutout. See
    /// `IdleMarkPosition` for why this is a preference and not a decision.
    public var idleMarkPosition: IdleMarkPosition {
        didSet { defaults.set(idleMarkPosition.rawValue, forKey: Key.idleMarkPosition) }
    }

    /// Haptic feedback on run transitions.
    public var haptics: Bool {
        didSet {
            defaults.set(haptics, forKey: Key.haptics)
            Haptics.isEnabled = haptics
        }
    }

    /// A Notification Centre banner when a deployment is waiting on **your**
    /// approval. Never for somebody else's — see `ApprovalCheck`.
    public var approvalNotifications: Bool {
        didSet {
            defaults.set(approvalNotifications, forKey: Key.approvalNotifications)
            ApprovalNotifier.isEnabled = approvalNotifications
        }
    }

    /// Whether a run the "whose runs" filter would hide may come back because
    /// it is parked on **your** review.
    ///
    /// Off by default, because the filter has to mean what it says. Inside an
    /// organization the account is usually a member of a reviewing team, so
    /// GitHub answers `current_user_can_approve: true` for every colleague's
    /// deploy on every environment that team guards — and "Only my runs"
    /// filled up with other people's pipelines, which is the opposite of what
    /// was ticked. Turn it on and they come back, deliberately.
    ///
    /// No effect under `.everyone`: nothing is being hidden there to restore.
    public var approvalsFromOthers: Bool {
        didSet { defaults.set(approvalsFromOthers, forKey: Key.approvalsFromOthers) }
    }

    // MARK: - Derived

    /// The filter the current settings resolve to, for previewing counts in the
    /// Settings window without duplicating the resolution rules.
    public var actorFilter: ActorFilter {
        ActorFilter.resolve(scope: actorScope, watched: watchedActors, currentUser: currentUser)
    }

    /// Add a login to the watch list, de-duplicated case-insensitively.
    public func watchActor(_ login: String) {
        let trimmed = login.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalised = trimmed.hasPrefix("@") && trimmed.lowercased() != ActorFilter.selfToken
            ? String(trimmed.dropFirst())
            : trimmed
        guard !watchedActors.contains(where: { $0.caseInsensitiveCompare(normalised) == .orderedSame })
        else { return }
        watchedActors.append(normalised)
    }

    /// Remove a login from the watch list.
    public func unwatchActor(_ login: String) {
        watchedActors.removeAll { $0.caseInsensitiveCompare(login) == .orderedSame }
    }
}
