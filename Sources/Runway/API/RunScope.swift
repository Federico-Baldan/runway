import Foundation

/// Which repositories the island watches.
///
/// GitHub has **no account-level endpoint** for "every run I can see" — the
/// GitLab original got that in one GraphQL query. Every option here therefore
/// resolves to a *list of repositories*, and the monitor fans out one request
/// per repository. That constraint is why `.recent` exists and is the default:
/// polling 200 repos to find the two you are actually working in is a waste of
/// a rate-limit budget.
public enum RepoScope: String, Sendable, CaseIterable, Codable {
    /// The N repositories with the most recent pushes. The default.
    case recent
    /// Only repositories owned by the signed-in account.
    case mine
    /// Repositories belonging to the organizations the user picked.
    case organizations
    /// An explicit hand-maintained list of `owner/repo`.
    case explicit

    public var label: String {
        switch self {
        case .recent: return "Recently active repositories"
        case .mine: return "My repositories only"
        case .organizations: return "Selected organizations"
        case .explicit: return "A list I choose"
        }
    }

    public var detail: String {
        switch self {
        case .recent:
            return "The repositories you pushed to most recently, whoever owns them."
        case .mine:
            return "Repositories owned by your account, personal ones included."
        case .organizations:
            return "Repositories belonging to the organizations you tick below."
        case .explicit:
            return "Only the owner/repo entries you add below. Nothing is discovered."
        }
    }
}

/// Whose runs to show — a separate axis from *which repositories* are watched.
///
/// The GitLab original had two options. This has three: being in a company's
/// org does not mean you want every colleague's push in your menu bar, but it
/// also does not mean you want *only* your own — you often want yours plus the
/// two people you are pairing with.
public enum ActorScope: String, Sendable, CaseIterable, Codable {
    /// Only runs the signed-in user pushed or re-ran.
    case me
    /// Every run, whoever started it.
    case everyone
    /// A hand-picked list of logins, with `@me` resolved at runtime.
    case list

    public var label: String {
        switch self {
        case .me: return "Only my runs"
        case .everyone: return "Everyone's runs"
        case .list: return "Specific people"
        }
    }

    public var detail: String {
        switch self {
        case .me: return "Your own pushes and re-runs. Colleagues' runs are hidden."
        case .everyone: return "Every run in the repositories above, whoever started it."
        case .list: return "Only the people you list below. Add @me to include yourself."
        }
    }
}

/// The resolved "whose runs" rule, ready to apply.
///
/// Holds logins rather than a scope enum so the monitor never has to know how
/// the user expressed the choice — `.me` and a one-entry `.list` produce the
/// same filter and are optimised identically.
public struct ActorFilter: Sendable, Equatable {
    /// The literal the user types to mean "whoever this token belongs to".
    public static let selfToken = "@me"

    /// Logins to keep. Empty means "keep everything".
    public let logins: Set<String>

    /// Everything passes.
    public static let everyone = ActorFilter(logins: [])

    public init(logins: Set<String>) {
        self.logins = Set(logins.map { $0.lowercased() })
    }

    /// Build the filter for a scope, resolving `@me` against the signed-in login.
    ///
    /// A `.list` that resolves to nothing — every entry was `@me` and the token
    /// has not been verified yet — degrades to `.everyone` rather than hiding
    /// every run. Showing too much beats an island that silently never appears.
    public static func resolve(
        scope: ActorScope,
        watched: [String],
        currentUser: String?
    ) -> ActorFilter {
        switch scope {
        case .everyone:
            return .everyone
        case .me:
            guard let currentUser, !currentUser.isEmpty else { return .everyone }
            return ActorFilter(logins: [currentUser])
        case .list:
            var resolved = Set<String>()
            for entry in watched {
                let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if trimmed.caseInsensitiveCompare(selfToken) == .orderedSame {
                    if let currentUser, !currentUser.isEmpty { resolved.insert(currentUser) }
                } else {
                    resolved.insert(trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed)
                }
            }
            return resolved.isEmpty ? .everyone : ActorFilter(logins: resolved)
        }
    }

    /// True when nothing is filtered out.
    public var isEveryone: Bool { logins.isEmpty }

    /// Why the `?actor=` query parameter is deliberately **not** used.
    ///
    /// It looks like free server-side filtering, and the first version of this
    /// used it whenever exactly one login was watched. Two measurements against
    /// the live API killed that:
    ///
    ///  * `?actor=` does not match `actor.login`. Filtering Homebrew/brew by
    ///    one maintainer returned 100 runs, two of which had a different
    ///    `actor.login` entirely. The parameter matches whoever *created the
    ///    push*, which is related to but not the same as the run's displayed
    ///    attribution. (`?actor=torvalds` returns 0, so it is filtering — just
    ///    not on the field the island shows.)
    ///
    ///  * It cannot see a re-run. The documented meaning is the push author, so
    ///    a run that a colleague pushed and *you* re-ran would not come back
    ///    from `?actor=<you>` — and it would never reach the local filter to be
    ///    rescued. That is precisely the case `involves(_:)` exists to catch,
    ///    and it would break under the default setting.
    ///
    /// The optimisation also bought nothing. `per_page` 10, 30 and 100 each
    /// cost exactly one request (measured: remaining 4933 -> 4932 -> 4931), so
    /// filtering server-side saves payload, never budget. Fetching one wider
    /// unfiltered page and filtering here costs the same and cannot silently
    /// drop a run.

    /// Does this run belong to somebody being watched?
    public func matches(_ run: WorkflowRun) -> Bool {
        guard !isEveryone else { return true }
        return run.logins.contains { logins.contains($0.lowercased()) }
    }

    /// Apply the filter to a batch.
    public func apply(_ runs: [WorkflowRun]) -> [WorkflowRun] {
        guard !isEveryone else { return runs }
        return runs.filter(matches)
    }
}

/// One repository being polled, plus what the poller has learned about it.
public struct WatchedRepo: Sendable, Hashable, Identifiable {
    public let fullName: String
    /// False once a poll comes back with `total_count == 0` — the repo has no
    /// Actions at all, so it is demoted to an occasional check rather than
    /// being polled every cycle alongside repos that are actually building.
    public var hasWorkflows: Bool
    /// Cycles skipped since this repo was last polled, for the demotion above.
    public var skippedCycles: Int

    public var id: String { fullName }

    public init(fullName: String, hasWorkflows: Bool = true, skippedCycles: Int = 0) {
        self.fullName = fullName
        self.hasWorkflows = hasWorkflows
        self.skippedCycles = skippedCycles
    }

    /// How many cycles a quiet repository waits between polls.
    public static let quietRepoInterval = 12

    /// Should this repository be polled on this cycle?
    public mutating func shouldPoll() -> Bool {
        guard !hasWorkflows else { return true }
        skippedCycles += 1
        guard skippedCycles >= Self.quietRepoInterval else { return false }
        skippedCycles = 0
        return true
    }
}
