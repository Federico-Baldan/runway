import Foundation
import SwiftUI

/// Environment-variable overrides.
///
/// The settings that decide *whose* runs appear are also the ones people most
/// want to set from outside the UI — per project, per checkout, from a dotfile.
/// Anything set here wins over the stored preference and is shown as locked in
/// Settings, so the UI never claims a value the app is not actually using.
///
/// One honest caveat, stated in the README too: a `LSUIElement` app launched
/// from Finder or as a login item does **not** inherit your shell environment.
/// These apply when Runway is started from a terminal (`make run`) or from a
/// launch agent that sets them. The Settings window is the durable path.
public enum EnvironmentOverride {
    public static let actorMode = "RUNWAY_ACTOR_MODE"
    public static let actors = "RUNWAY_ACTORS"
    public static let repoScope = "RUNWAY_REPO_SCOPE"
    public static let repositories = "RUNWAY_REPOS"
    public static let repoLimit = "RUNWAY_REPO_LIMIT"
    public static let organizations = "RUNWAY_ORGS"
    public static let host = "RUNWAY_HOST"

    /// Every variable Runway reads, for `--diagnose` and the README.
    public static let all = [
        actorMode, actors, repoScope, repositories, repoLimit, organizations, host,
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
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        self.host = EnvironmentOverride.string(EnvironmentOverride.host)
            ?? defaults.string(forKey: Key.host)
            ?? "https://github.com"

        self.screenPreference = NotchGeometry.ScreenPreference(
            rawValue: defaults.string(forKey: Key.screenPreference) ?? ""
        ) ?? .primary

        self.repoScope = EnvironmentOverride.string(EnvironmentOverride.repoScope)
            .flatMap(RepoScope.init(rawValue:))
            ?? RepoScope(rawValue: defaults.string(forKey: Key.repoScope) ?? "")
            ?? .recent

        self.repoLimit = EnvironmentOverride.int(EnvironmentOverride.repoLimit)
            ?? (defaults.object(forKey: Key.repoLimit) as? Int)
            ?? 20

        self.organizations = Set(
            EnvironmentOverride.list(EnvironmentOverride.organizations)
                ?? defaults.stringArray(forKey: Key.organizations)
                ?? []
        )

        self.explicitRepositories = EnvironmentOverride.list(EnvironmentOverride.repositories)
            ?? defaults.stringArray(forKey: Key.explicitRepositories)
            ?? []

        self.actorScope = EnvironmentOverride.string(EnvironmentOverride.actorMode)
            .flatMap(ActorScope.init(rawValue:))
            ?? ActorScope(rawValue: defaults.string(forKey: Key.actorScope) ?? "")
            ?? .me

        self.watchedActors = EnvironmentOverride.list(EnvironmentOverride.actors)
            ?? defaults.stringArray(forKey: Key.watchedActors)
            ?? [ActorFilter.selfToken]

        self.currentUser = defaults.string(forKey: Key.currentUser)
        self.haptics = defaults.object(forKey: Key.haptics) as? Bool ?? true

        // `RUNWAY_ACTORS` without `RUNWAY_ACTOR_MODE` reads as "watch these
        // people" — honouring the list but leaving the mode on `.me` would
        // silently ignore it.
        if EnvironmentOverride.isSet(EnvironmentOverride.actors),
           !EnvironmentOverride.isSet(EnvironmentOverride.actorMode) {
            self.actorScope = .list
        }
        // Same reasoning for an explicit repository list.
        if EnvironmentOverride.isSet(EnvironmentOverride.repositories),
           !EnvironmentOverride.isSet(EnvironmentOverride.repoScope) {
            self.repoScope = .explicit
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

    /// Haptic feedback on run transitions.
    public var haptics: Bool {
        didSet {
            defaults.set(haptics, forKey: Key.haptics)
            Haptics.isEnabled = haptics
        }
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
