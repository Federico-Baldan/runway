import Foundation

// MARK: - Pending deployments

/// One environment a workflow run is parked on, waiting for a human.
///
/// Decoded from `GET /repos/{owner}/{repo}/actions/runs/{run_id}/pending_deployments`.
/// GitHub lists that endpoint under **Actions: Read** — the same permission
/// Runway already needs for runs and jobs — so reading approvals costs nothing
/// on the token. *Granting* one is a `POST` under Deployments: write, and
/// Runway deliberately does not ask for it: the island tells you an approval is
/// waiting and opens the run; GitHub is where you click Approve.
public struct PendingDeployment: Codable, Sendable, Hashable, Identifiable {
    /// The environment itself — `production`, `staging`, whatever it was named.
    public struct Environment: Codable, Sendable, Hashable {
        public let id: Int
        public let name: String
        public let htmlURL: String?

        public init(id: Int = 0, name: String, htmlURL: String? = nil) {
            self.id = id
            self.name = name
            self.htmlURL = htmlURL
        }

        private enum CodingKeys: String, CodingKey {
            case id, name
            case htmlURL = "html_url"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(Int.self, forKey: .id) ?? 0
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? "environment"
            htmlURL = try container.decodeIfPresent(String.self, forKey: .htmlURL)
        }
    }

    /// How long the environment's wait timer is set to, in minutes. `0` when
    /// the only gate is a person.
    public let waitTimer: Int
    public let waitTimerStartedAt: Date?
    /// GitHub's own answer to "can the account this token belongs to unblock
    /// this?". The single most useful field in the API for a status app: it is
    /// the difference between a notification you can act on and noise about
    /// somebody else's deploy.
    public let currentUserCanApprove: Bool
    public let environment: Environment
    public let reviewers: [DeploymentReviewer]

    public var id: String { "\(environment.id)/\(environment.name)" }

    public init(
        environment: Environment,
        waitTimer: Int = 0,
        waitTimerStartedAt: Date? = nil,
        currentUserCanApprove: Bool = false,
        reviewers: [DeploymentReviewer] = []
    ) {
        self.environment = environment
        self.waitTimer = waitTimer
        self.waitTimerStartedAt = waitTimerStartedAt
        self.currentUserCanApprove = currentUserCanApprove
        self.reviewers = reviewers
    }

    private enum CodingKeys: String, CodingKey {
        case environment, reviewers
        case waitTimer = "wait_timer"
        case waitTimerStartedAt = "wait_timer_started_at"
        case currentUserCanApprove = "current_user_can_approve"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        environment = try container.decode(Environment.self, forKey: .environment)
        waitTimer = try container.decodeIfPresent(Int.self, forKey: .waitTimer) ?? 0
        waitTimerStartedAt = try container.decodeIfPresent(Date.self, forKey: .waitTimerStartedAt)
        currentUserCanApprove =
            try container.decodeIfPresent(Bool.self, forKey: .currentUserCanApprove) ?? false
        reviewers = try container.decodeIfPresent([DeploymentReviewer].self, forKey: .reviewers) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(environment, forKey: .environment)
        try container.encode(waitTimer, forKey: .waitTimer)
        try container.encodeIfPresent(waitTimerStartedAt, forKey: .waitTimerStartedAt)
        try container.encode(currentUserCanApprove, forKey: .currentUserCanApprove)
        try container.encode(reviewers, forKey: .reviewers)
    }

    /// Seconds still to run on the wait timer, or `nil` when there isn't one.
    ///
    /// A wait timer and a required reviewer are different gates that look
    /// identical from outside — both report `waiting` — and only one of them
    /// will ever move on its own.
    public func waitRemaining(now: Date = Date()) -> TimeInterval? {
        guard waitTimer > 0, let startedAt = waitTimerStartedAt else { return nil }
        let ends = startedAt.addingTimeInterval(TimeInterval(waitTimer) * 60)
        let remaining = ends.timeIntervalSince(now)
        return remaining > 0 ? remaining : nil
    }
}

/// Somebody GitHub will accept an approval from — a person or a team.
public struct DeploymentReviewer: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case user = "User"
        case team = "Team"
        case unknown
    }

    public let kind: Kind
    /// A user's `login`, or a team's `slug`.
    public let name: String

    public var id: String { "\(kind.rawValue):\(name)" }

    public init(kind: Kind, name: String) {
        self.kind = kind
        self.name = name
    }

    private enum CodingKeys: String, CodingKey {
        case type, reviewer
    }

    /// The reviewer's own keys. A user carries `login`; a team carries `slug`
    /// and `name`, and the slug is what appears in GitHub's own UI.
    private enum ReviewerKeys: String, CodingKey {
        case login, slug, name
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        kind = Kind(rawValue: rawType) ?? .unknown

        guard let reviewer = try? container.nestedContainer(
            keyedBy: ReviewerKeys.self, forKey: .reviewer
        ) else {
            name = "someone"
            return
        }

        // A user carries `login`, a team `slug`, and a team that predates slugs
        // only `name`. Take whichever is there and non-empty.
        // `try?` flattens the double optional a throwing `decodeIfPresent`
        // would otherwise hand back, so this is one binding, not two.
        func text(_ key: ReviewerKeys) -> String? {
            guard let value = try? reviewer.decodeIfPresent(String.self, forKey: key),
                  !value.isEmpty else { return nil }
            return value
        }
        name = text(.login) ?? text(.slug) ?? text(.name) ?? "someone"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .type)
        var reviewer = container.nestedContainer(keyedBy: ReviewerKeys.self, forKey: .reviewer)
        switch kind {
        case .team:
            try reviewer.encode(name, forKey: .slug)
        case .user, .unknown:
            try reviewer.encode(name, forKey: .login)
        }
    }

    /// `@alice`, the way GitHub writes it — teams included, since the slug is
    /// what appears on the review dialog.
    public var handle: String { "@\(name)" }
}

// MARK: - Review history

/// One answer already given to a deployment gate.
///
/// Decoded from `GET /repos/{owner}/{repo}/actions/runs/{run_id}/approvals`,
/// the mirror of `pending_deployments`: that endpoint lists the reviews a run is
/// still waiting on, this one lists the reviews it has received. Same **Actions:
/// Read** permission, so it costs the token nothing extra — which is the only
/// reason Runway can answer the question at all.
///
/// The question being: *why is this run red?* GitHub reports a deployment a
/// reviewer turned down as `conclusion: "failure"`, indistinguishable in the
/// runs list from a build that fell over. Here it is `state: "rejected"`, with
/// the person and their comment attached. See `RunStatus.rejected`.
public struct DeploymentReview: Codable, Sendable, Hashable {
    public enum State: String, Codable, Sendable {
        case approved
        case rejected
        /// A gate somebody has opened the dialog on but not answered.
        case pending
        case unknown
    }

    public let state: State
    /// Who answered. Optional because a review recorded by an app or by a
    /// deleted account can arrive without one.
    public let user: GitHubActor?
    /// What they typed in the box. Empty far more often than not.
    public let comment: String
    /// The environments this one answer covered — a reviewer approving a run
    /// parked on two of them produces one review naming both.
    public let environments: [PendingDeployment.Environment]

    public init(
        state: State,
        user: GitHubActor? = nil,
        comment: String = "",
        environments: [PendingDeployment.Environment] = []
    ) {
        self.state = state
        self.user = user
        self.comment = comment
        self.environments = environments
    }

    private enum CodingKeys: String, CodingKey {
        case state, user, comment, environments
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent(String.self, forKey: .state) ?? ""
        // Unrecognised rather than thrown. A new state on this endpoint would
        // otherwise fail the decode and take the whole review history with it,
        // and a run drawn as a plain failure is a much better outcome than a
        // poll that errors — which is exactly what the app did before there was
        // any of this.
        state = State(rawValue: raw.lowercased()) ?? .unknown
        user = try container.decodeIfPresent(GitHubActor.self, forKey: .user)
        comment = try container.decodeIfPresent(String.self, forKey: .comment) ?? ""
        environments = try container.decodeIfPresent(
            [PendingDeployment.Environment].self, forKey: .environments
        ) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state.rawValue, forKey: .state)
        try container.encodeIfPresent(user, forKey: .user)
        try container.encode(comment, forKey: .comment)
        try container.encode(environments, forKey: .environments)
    }

    /// `@alice`, the way GitHub writes it.
    public var handle: String? { user.map { "@\($0.login)" } }
}

// MARK: - The check

/// Does this run need a person, and does it need *you*?
///
/// Split out from both the UI and the notifier so the decision is one pure
/// function over a `WorkflowRun`, testable without a network, a keychain or a
/// screen — `spike/ApprovalVerify.swift` pins it.
///
/// The distinction it exists to make: a run blocked on an approval is worth
/// **showing** whoever is looking at the island, and worth **interrupting**
/// only the person who can actually unblock it. Notifying everyone in an
/// organization every time a colleague's deploy reaches production is how a
/// status app gets muted.
public enum ApprovalCheck {
    public enum Verdict: Sendable, Equatable {
        /// Blocked, and GitHub says this account may approve it. Notify.
        case needsMe(environments: [String])
        /// Blocked on somebody else's click. Show it; stay quiet.
        case needsOthers(environments: [String], reviewers: [String])
        /// Blocked, with no reviewer detail to go on — a first-time
        /// contributor gate, or a token that could not read the environments.
        /// Show it; stay quiet, because "somebody must approve this" is not
        /// the same as "you must approve this".
        case blocked
        /// Nothing is waiting on a human.
        case clear

        /// Whether the island should draw this run as blocked on a person.
        public var isBlocked: Bool { self != .clear }

        /// Whether this warrants breaking into someone's afternoon.
        public var deservesNotification: Bool {
            if case .needsMe = self { return true }
            return false
        }

        /// The environments involved, in the order GitHub returned them.
        public var environments: [String] {
            switch self {
            case .needsMe(let environments): return environments
            case .needsOthers(let environments, _): return environments
            case .blocked, .clear: return []
            }
        }
    }

    /// The verdict for one run.
    ///
    /// Reads the run's own status first and the pending-deployment detail
    /// second, because they arrive at different times: `waiting` shows up in
    /// the runs list, the environments only after a second request. A run is
    /// therefore drawn as blocked immediately and gains its detail a moment
    /// later, rather than flickering into existence once both have landed.
    public static func verdict(for run: WorkflowRun) -> Verdict {
        let approvable = run.pendingDeployments.filter(\.currentUserCanApprove)
        if !approvable.isEmpty {
            return .needsMe(environments: approvable.map(\.environment.name))
        }

        if !run.pendingDeployments.isEmpty {
            return .needsOthers(
                environments: run.pendingDeployments.map(\.environment.name),
                reviewers: run.pendingDeployments
                    .flatMap(\.reviewers)
                    .map(\.name)
                    .reduced()
            )
        }

        let blockedByStatus = run.status.isAwaitingApproval
            || run.jobs.contains { $0.status.isAwaitingApproval }
        return blockedByStatus ? .blocked : .clear
    }
}

private extension Array where Element == String {
    /// De-duplicated, first-appearance order preserved.
    func reduced() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}

// MARK: - Derived

public extension WorkflowRun {
    /// What, if anything, this run is waiting on a person for.
    ///
    /// Builds the environment and reviewer lists, so it is for the places that
    /// need the *words* — the chip, the banner, the tooltip. The two questions
    /// asked on every redraw have their own answers below.
    var approval: ApprovalCheck.Verdict { ApprovalCheck.verdict(for: self) }

    /// Blocked on a human rather than a runner.
    ///
    /// Deliberately not `approval.isBlocked`. This is read inside a sort
    /// comparator, on every run, on every one-second tick — and the comparator
    /// alone asks it twice per comparison. Going through the verdict would
    /// allocate two arrays each time to answer a question that is three
    /// pointer chases. `spike/ApprovalVerify.swift` asserts the fast path and
    /// the verdict agree on every fixture, which is the price of having two.
    var isBlockedOnApproval: Bool {
        if !pendingDeployments.isEmpty { return true }
        if status.isAwaitingApproval { return true }
        return jobs.contains { $0.status.isAwaitingApproval }
    }

    /// GitHub says this account can unblock it.
    var awaitsMyApproval: Bool {
        pendingDeployments.contains { $0.currentUserCanApprove }
    }

    /// A short line for the island: `production` or `production, staging`.
    var blockedEnvironmentLabel: String? {
        let environments = approval.environments
        guard !environments.isEmpty else { return nil }
        return environments.joined(separator: ", ")
    }

    /// The sentence the island and the notification both use, so they can never
    /// disagree about what is happening.
    var approvalSummary: String? {
        switch approval {
        case .needsMe(let environments):
            return environments.isEmpty
                ? "waiting for your approval"
                : "you can approve \(environments.joined(separator: ", "))"
        case .needsOthers(let environments, let reviewers):
            let who: String
            if let first = reviewers.first {
                who = reviewers.count == 1 ? "@\(first)" : "@\(first) +\(reviewers.count - 1)"
            } else {
                who = "a reviewer"
            }
            return environments.isEmpty
                ? "waiting for \(who)"
                : "\(environments.joined(separator: ", ")) — waiting for \(who)"
        case .blocked:
            return "waiting for approval"
        case .clear:
            return nil
        }
    }

    /// The sentence for a run somebody turned down, or `nil` for every other
    /// run.
    ///
    /// Deliberately names the person. "Rejected" on its own invites the same
    /// question every time — *by whom?* — and this is a status app: the whole
    /// point is not having to open a browser to find out.
    var rejectionSummary: String? {
        guard status == .rejected else { return nil }
        let environments = decisiveReview?.environments.map(\.name) ?? []
        let destination = environments.isEmpty
            ? ""
            : " to \(environments.joined(separator: ", "))"
        guard let who = rejectedBy else { return "deploy\(destination) was rejected" }
        return "@\(who) rejected the deploy\(destination)"
    }

    /// How far through its steps the run is, `0…1`.
    ///
    /// Steps when they have arrived, jobs when they have not, so the ring is
    /// never empty on a run whose detail is still a request away.
    var progress: Double {
        let steps = jobs.flatMap(\.steps)
        let statuses = steps.isEmpty ? jobs.map(\.status) : steps.map(\.status)
        guard !statuses.isEmpty else { return 0 }
        let settled = statuses.filter(\.isTerminal).count
        return min(max(Double(settled) / Double(statuses.count), 0), 1)
    }
}

public extension Job {
    /// This job is the one holding the run up.
    var isBlockedOnApproval: Bool { status.isAwaitingApproval }
}
