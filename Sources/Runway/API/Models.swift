import Foundation

// MARK: - Status

/// One fused status for a workflow run, a job, or a step.
///
/// GitHub splits this across **two** fields, which is the single biggest
/// modelling difference from GitLab. A run carries `status` (is it moving?)
/// *and* `conclusion` (how did it end?), and `conclusion` is `null` for
/// anything still in flight:
///
/// ```json
/// { "status": "in_progress", "conclusion": null    }   // running
/// { "status": "completed",   "conclusion": "failure" } // failed
/// ```
///
/// Reading only `status` makes every finished run look identical — the reason
/// `resolve(status:conclusion:)` exists and why nothing else in the app is
/// allowed to look at the raw pair.
public enum RunStatus: String, Codable, Sendable, CaseIterable {
    // In flight.
    case queued
    case inProgress
    case waiting
    case requested
    case pending

    // Finished.
    case success
    case failure
    case cancelled
    case skipped
    case neutral
    case timedOut
    case actionRequired
    case startupFailure
    case stale

    case unknown

    /// Fuse GitHub's `status` + `conclusion` pair into one value.
    ///
    /// `conclusion` wins whenever it is present: a run can report
    /// `status: "completed"` with any of a dozen conclusions, and the
    /// conclusion is the part a human cares about.
    public static func resolve(status: String?, conclusion: String?) -> RunStatus {
        if let conclusion, !conclusion.isEmpty {
            switch conclusion.lowercased() {
            case "success": return .success
            case "failure": return .failure
            case "cancelled", "canceled": return .cancelled
            case "skipped": return .skipped
            case "neutral": return .neutral
            case "timed_out": return .timedOut
            case "action_required": return .actionRequired
            case "startup_failure": return .startupFailure
            case "stale": return .stale
            default: return .unknown
            }
        }
        switch (status ?? "").lowercased() {
        case "queued": return .queued
        case "in_progress": return .inProgress
        case "waiting": return .waiting
        case "requested": return .requested
        case "pending": return .pending
        // `completed` with a null conclusion should not happen, but the API is
        // eventually consistent and it is observed briefly on fresh runs.
        case "completed": return .unknown
        default: return .unknown
        }
    }

    /// Active means "this run is going somewhere" — poll fast.
    public var isActive: Bool {
        switch self {
        case .queued, .inProgress, .waiting, .requested, .pending:
            return true
        case .success, .failure, .cancelled, .skipped, .neutral, .timedOut,
             .actionRequired, .startupFailure, .stale, .unknown:
            return false
        }
    }

    /// A finished run that will not change again.
    ///
    /// `actionRequired` is deliberately excluded: a run waiting on a deployment
    /// approval is finished as far as the API is concerned, but it *will* move
    /// again once somebody clicks approve.
    public var isTerminal: Bool {
        switch self {
        case .success, .failure, .cancelled, .skipped, .timedOut,
             .startupFailure, .stale, .neutral:
            return true
        case .actionRequired, .queued, .inProgress, .waiting, .requested,
             .pending, .unknown:
            return false
        }
    }

    /// Anything a human would read as "this broke".
    public var isFailure: Bool {
        switch self {
        case .failure, .timedOut, .startupFailure:
            return true
        default:
            return false
        }
    }

    /// Parked waiting for a **person**, not for a runner.
    ///
    /// Two different GitHub mechanisms land here and the API spells them
    /// differently, which is why this is one property rather than a comparison:
    ///
    ///  * `status: "waiting"` — a deployment job pointed at an environment with
    ///    required reviewers. The run is still in flight; nothing will move
    ///    until somebody clicks *Approve and deploy*.
    ///  * `conclusion: "action_required"` — the run stopped and is asking for
    ///    something, most often a maintainer approving a first-time
    ///    contributor's pull request.
    ///
    /// Neither is a failure and neither is progress, and a CI island that draws
    /// them as either is lying about who is blocked.
    public var isAwaitingApproval: Bool {
        switch self {
        case .waiting, .actionRequired:
            return true
        default:
            return false
        }
    }

    /// Lowercase label for tooltips.
    public var label: String {
        switch self {
        case .inProgress: return "in progress"
        case .timedOut: return "timed out"
        case .actionRequired: return "action required"
        case .startupFailure: return "startup failure"
        default: return rawValue
        }
    }
}

// MARK: - People

/// A GitHub account, as it appears on a run.
public struct GitHubActor: Codable, Sendable, Hashable, Identifiable {
    public let login: String
    public let avatarURL: String?
    public let htmlURL: String?

    public var id: String { login }

    public init(login: String, avatarURL: String? = nil, htmlURL: String? = nil) {
        self.login = login
        self.avatarURL = avatarURL
        self.htmlURL = htmlURL
    }

    private enum CodingKeys: String, CodingKey {
        case login
        case avatarURL = "avatar_url"
        case htmlURL = "html_url"
    }
}

// MARK: - Steps and jobs

/// One step inside a job — the `- name: …` entries in the workflow YAML.
///
/// Maps to what GitLab called a *job*: the smallest unit with its own dot in
/// the island's strip.
public struct Step: Codable, Sendable, Hashable, Identifiable {
    public let name: String
    public let number: Int
    public let status: RunStatus
    public let startedAt: Date?
    public let completedAt: Date?

    public var id: String { "\(number)/\(name)" }

    public init(
        name: String,
        number: Int,
        status: RunStatus,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.name = name
        self.number = number
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    private enum CodingKeys: String, CodingKey {
        case name, number, status, conclusion
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        number = try container.decodeIfPresent(Int.self, forKey: .number) ?? 0
        status = RunStatus.resolve(
            status: try container.decodeIfPresent(String.self, forKey: .status),
            conclusion: try container.decodeIfPresent(String.self, forKey: .conclusion)
        )
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(number, forKey: .number)
        try container.encode(status.rawValue, forKey: .status)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
    }
}

/// One job inside a workflow run — a `jobs:` key in the workflow YAML.
///
/// Maps to what GitLab called a *stage*: the horizontal grouping the island
/// draws as a labelled row of dots.
public struct Job: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let name: String
    public let status: RunStatus
    public let startedAt: Date?
    public let completedAt: Date?
    public let htmlURL: String?
    public let steps: [Step]

    public init(
        id: Int,
        name: String,
        status: RunStatus,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        htmlURL: String? = nil,
        steps: [Step] = []
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.htmlURL = htmlURL
        self.steps = steps
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion, steps
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case htmlURL = "html_url"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id) ?? 0
        name = try container.decode(String.self, forKey: .name)
        status = RunStatus.resolve(
            status: try container.decodeIfPresent(String.self, forKey: .status),
            conclusion: try container.decodeIfPresent(String.self, forKey: .conclusion)
        )
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        htmlURL = try container.decodeIfPresent(String.self, forKey: .htmlURL)
        steps = try container.decodeIfPresent([Step].self, forKey: .steps) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(status.rawValue, forKey: .status)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encodeIfPresent(htmlURL, forKey: .htmlURL)
        try container.encode(steps, forKey: .steps)
    }

    /// Steps still executing.
    public var runningSteps: [Step] { steps.filter { $0.status == .inProgress } }

    /// Wall time, live for a running job.
    public var duration: TimeInterval? {
        guard let startedAt else { return nil }
        return (completedAt ?? Date()).timeIntervalSince(startedAt)
    }
}

// MARK: - Workflow run

/// One GitHub Actions workflow run.
public struct WorkflowRun: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    /// Workflow name, e.g. `build`.
    public let name: String?
    /// The workflow's own file, e.g. `.github/workflows/deploy-prod.yml`.
    ///
    /// Decoded for `DeployClassifier` and nothing else. A workflow's `name:`
    /// key is often the generic half — "CI", "build" — while whoever wrote the
    /// file was specific about what it does, so the path is regularly the
    /// better of the two names to read an environment out of.
    public let path: String?
    /// The commit subject GitHub shows next to the run.
    public let displayTitle: String?
    public let runNumber: Int
    public let runAttempt: Int
    public let headBranch: String?
    public let headSHA: String?
    /// What kicked it off: `push`, `pull_request`, `schedule`, `workflow_dispatch`…
    public let event: String?
    public let status: RunStatus
    public let htmlURL: String?
    public let createdAt: Date?
    public let updatedAt: Date?
    public let runStartedAt: Date?
    /// Who caused the run. `nil` for some system triggers.
    public let actor: GitHubActor?
    /// Who triggered *this attempt* — differs from `actor` on a re-run.
    public let triggeringActor: GitHubActor?

    /// `owner/repo`. Stamped by `GitHubClient` after decoding: the per-repo
    /// endpoint does not repeat the repository on every run.
    public var repository: String = ""

    /// Jobs, fetched lazily. Empty until the run is worth a second request —
    /// see `RunMonitor.shouldFetchJobs`.
    public var jobs: [Job] = []

    /// Environments this run is parked on, waiting for a human to approve.
    ///
    /// A third request, and the rarest: it is only ever made for a run that has
    /// already said it is waiting — see `RunMonitor.shouldFetchApprovals`. Not
    /// decoded from the run payload because GitHub does not put it there; it
    /// comes from `/actions/runs/{id}/pending_deployments`, which the same
    /// **Actions: Read** permission already covers.
    public var pendingDeployments: [PendingDeployment] = []

    /// Where this run is deploying, if anything about it says so.
    ///
    /// Stamped, not computed, and not decoded from anything — GitHub does not
    /// put an environment on a workflow run. `DeployClassifier` derives it
    /// from the names already in the payload, and `RunMonitor` stamps it once
    /// per poll after the jobs and the pending deployments have landed, since
    /// both feed the answer. `nil` is the normal case: most runs are builds
    /// and deploy nowhere.
    public var deployTarget: DeployTarget?

    public init(
        id: Int,
        name: String? = nil,
        path: String? = nil,
        displayTitle: String? = nil,
        runNumber: Int = 0,
        runAttempt: Int = 1,
        headBranch: String? = nil,
        headSHA: String? = nil,
        event: String? = nil,
        status: RunStatus,
        htmlURL: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        runStartedAt: Date? = nil,
        actor: GitHubActor? = nil,
        triggeringActor: GitHubActor? = nil,
        repository: String = "",
        jobs: [Job] = [],
        pendingDeployments: [PendingDeployment] = []
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.displayTitle = displayTitle
        self.runNumber = runNumber
        self.runAttempt = runAttempt
        self.headBranch = headBranch
        self.headSHA = headSHA
        self.event = event
        self.status = status
        self.htmlURL = htmlURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.runStartedAt = runStartedAt
        self.actor = actor
        self.triggeringActor = triggeringActor
        self.repository = repository
        self.jobs = jobs
        self.pendingDeployments = pendingDeployments
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, path, status, conclusion, event, actor
        case displayTitle = "display_title"
        case runNumber = "run_number"
        case runAttempt = "run_attempt"
        case headBranch = "head_branch"
        case headSHA = "head_sha"
        case htmlURL = "html_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case runStartedAt = "run_started_at"
        case triggeringActor = "triggering_actor"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        displayTitle = try container.decodeIfPresent(String.self, forKey: .displayTitle)
        runNumber = try container.decodeIfPresent(Int.self, forKey: .runNumber) ?? 0
        runAttempt = try container.decodeIfPresent(Int.self, forKey: .runAttempt) ?? 1
        headBranch = try container.decodeIfPresent(String.self, forKey: .headBranch)
        headSHA = try container.decodeIfPresent(String.self, forKey: .headSHA)
        event = try container.decodeIfPresent(String.self, forKey: .event)
        status = RunStatus.resolve(
            status: try container.decodeIfPresent(String.self, forKey: .status),
            conclusion: try container.decodeIfPresent(String.self, forKey: .conclusion)
        )
        htmlURL = try container.decodeIfPresent(String.self, forKey: .htmlURL)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        runStartedAt = try container.decodeIfPresent(Date.self, forKey: .runStartedAt)
        actor = try container.decodeIfPresent(GitHubActor.self, forKey: .actor)
        triggeringActor = try container.decodeIfPresent(GitHubActor.self, forKey: .triggeringActor)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(path, forKey: .path)
        try container.encodeIfPresent(displayTitle, forKey: .displayTitle)
        try container.encode(runNumber, forKey: .runNumber)
        try container.encode(runAttempt, forKey: .runAttempt)
        try container.encodeIfPresent(headBranch, forKey: .headBranch)
        try container.encodeIfPresent(headSHA, forKey: .headSHA)
        try container.encodeIfPresent(event, forKey: .event)
        try container.encode(status.rawValue, forKey: .status)
        try container.encodeIfPresent(htmlURL, forKey: .htmlURL)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(runStartedAt, forKey: .runStartedAt)
        try container.encodeIfPresent(actor, forKey: .actor)
        try container.encodeIfPresent(triggeringActor, forKey: .triggeringActor)
    }

    // MARK: Derived

    /// Stable identity for one run attempt.
    public var identity: String { "\(repository)#\(id)/\(runAttempt)" }

    public var isActive: Bool { status.isActive }

    /// Last path component of `owner/repo` — what the island pill shows.
    public var repositoryName: String {
        repository.split(separator: "/").last.map(String.init) ?? repository
    }

    /// Workflow name, falling back to the commit subject then the run number.
    public var title: String {
        if let name, !name.isEmpty { return name }
        if let displayTitle, !displayTitle.isEmpty { return displayTitle }
        return "run #\(runNumber)"
    }

    /// Everyone this run can be attributed to.
    ///
    /// Both are checked because they diverge on a re-run: `actor` stays the
    /// person who pushed, `triggeringActor` becomes whoever clicked *Re-run*.
    /// Filtering on only one silently loses runs the user would expect to see.
    public var logins: Set<String> {
        var result = Set<String>()
        if let actor { result.insert(actor.login) }
        if let triggeringActor { result.insert(triggeringActor.login) }
        return result
    }

    /// True when `login` pushed this run or re-ran it.
    public func involves(_ login: String) -> Bool {
        logins.contains { $0.caseInsensitiveCompare(login) == .orderedSame }
    }

    /// A re-run someone else kicked off.
    public var isRerun: Bool {
        runAttempt > 1 || (actor?.login != triggeringActor?.login && triggeringActor != nil)
    }

    public var jobList: [Job] { jobs }
    public var runningJobs: [Job] { jobs.filter { $0.status.isActive } }
    public var failedJobs: [Job] { jobs.filter { $0.status.isFailure } }

    /// Steps currently executing, across every job.
    public var runningSteps: [Step] { jobs.flatMap(\.runningSteps) }

    /// When the clock started. `runStartedAt` is absent on very fresh runs.
    public var startedAt: Date? { runStartedAt ?? createdAt }

    /// When the run stopped, or nil while it is still going.
    ///
    /// GitHub has no `finished_at`. For a completed run `updated_at` is the
    /// closest thing: it is stamped when the run reaches its conclusion.
    public var finishedAt: Date? {
        guard !status.isActive else { return nil }
        return updatedAt
    }

    /// Wall-clock seconds, or nil if it never started.
    ///
    /// Also unlike GitLab, which hands over a `duration` field — this is
    /// computed, and it is wall time, not billable time.
    public var duration: TimeInterval? {
        guard let startedAt else { return nil }
        guard let finishedAt else { return nil }
        return max(finishedAt.timeIntervalSince(startedAt), 0)
    }

    /// Web URL for click-through. The API hands this over directly, so unlike
    /// the GitLab original there is no id-vs-iid trap to fall into.
    public func webURL() -> URL? {
        if let htmlURL, let url = URL(string: htmlURL) { return url }
        guard !repository.isEmpty else { return nil }
        return URL(string: "https://github.com/\(repository)/actions/runs/\(id)")
    }

    /// Change signature for dedupe: identity, status, jobs, running steps,
    /// what the run is waiting on, and where it is going.
    ///
    /// The approval part is not decoration. Everything downstream — the island
    /// redrawing, the notification firing — hangs off this string differing,
    /// and a run that goes from *blocked on production* to *blocked on
    /// production, and you can approve it* changes nothing else about itself.
    public var signature: String {
        let jobPart = jobs
            .map { "\($0.name):\($0.status.rawValue)" }
            .joined(separator: ",")
        let stepPart = runningSteps
            .map(\.name)
            .sorted()
            .joined(separator: ",")
        let approvalPart = pendingDeployments
            .map { "\($0.environment.name):\($0.currentUserCanApprove)" }
            .sorted()
            .joined(separator: ",")
        // The target moves when the jobs land, and again if a gate turns a
        // guess read off a job name into the name GitHub actually uses.
        let environmentPart = deployTarget.map { "\($0.name):\($0.tier.rawValue)" } ?? ""
        return "\(identity)|\(status.rawValue)|\(jobPart)|\(stepPart)"
            + "|\(approvalPart)|\(environmentPart)"
    }
}

// MARK: - Repository

/// A repository the app may watch.
public struct Repository: Codable, Sendable, Hashable, Identifiable {
    public let fullName: String
    public let isPrivate: Bool
    public let isArchived: Bool
    public let isFork: Bool
    public let pushedAt: Date?
    public let owner: GitHubActor?

    public var id: String { fullName }

    public init(
        fullName: String,
        isPrivate: Bool = false,
        isArchived: Bool = false,
        isFork: Bool = false,
        pushedAt: Date? = nil,
        owner: GitHubActor? = nil
    ) {
        self.fullName = fullName
        self.isPrivate = isPrivate
        self.isArchived = isArchived
        self.isFork = isFork
        self.pushedAt = pushedAt
        self.owner = owner
    }

    private enum CodingKeys: String, CodingKey {
        case owner
        case fullName = "full_name"
        case isPrivate = "private"
        case isArchived = "archived"
        case isFork = "fork"
        case pushedAt = "pushed_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fullName = try container.decode(String.self, forKey: .fullName)
        isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        isFork = try container.decodeIfPresent(Bool.self, forKey: .isFork) ?? false
        pushedAt = try container.decodeIfPresent(Date.self, forKey: .pushedAt)
        owner = try container.decodeIfPresent(GitHubActor.self, forKey: .owner)
    }

    /// `owner` half of `owner/repo`.
    public var ownerLogin: String {
        fullName.split(separator: "/").first.map(String.init) ?? ""
    }

    /// `repo` half of `owner/repo`.
    public var shortName: String {
        fullName.split(separator: "/").last.map(String.init) ?? fullName
    }
}

/// An organization the account belongs to.
public struct Organization: Codable, Sendable, Hashable, Identifiable {
    public let login: String
    public let avatarURL: String?

    public var id: String { login }

    public init(login: String, avatarURL: String? = nil) {
        self.login = login
        self.avatarURL = avatarURL
    }

    private enum CodingKeys: String, CodingKey {
        case login
        case avatarURL = "avatar_url"
    }
}

// MARK: - Envelopes

/// `GET /repos/{owner}/{repo}/actions/runs`
public struct WorkflowRunsPayload: Codable, Sendable {
    public let totalCount: Int
    public let workflowRuns: [WorkflowRun]

    private enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case workflowRuns = "workflow_runs"
    }

    public init(totalCount: Int, workflowRuns: [WorkflowRun]) {
        self.totalCount = totalCount
        self.workflowRuns = workflowRuns
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalCount = try container.decodeIfPresent(Int.self, forKey: .totalCount) ?? 0
        workflowRuns = try container.decodeIfPresent([WorkflowRun].self, forKey: .workflowRuns) ?? []
    }
}

/// `GET /repos/{owner}/{repo}/actions/runs/{run_id}/jobs`
public struct JobsPayload: Codable, Sendable {
    public let totalCount: Int
    public let jobs: [Job]

    private enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case jobs
    }

    public init(totalCount: Int, jobs: [Job]) {
        self.totalCount = totalCount
        self.jobs = jobs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalCount = try container.decodeIfPresent(Int.self, forKey: .totalCount) ?? 0
        jobs = try container.decodeIfPresent([Job].self, forKey: .jobs) ?? []
    }
}

/// `GET /user`
public struct AuthenticatedUser: Codable, Sendable {
    public let login: String
    public let name: String?
    public let avatarURL: String?

    private enum CodingKeys: String, CodingKey {
        case login, name
        case avatarURL = "avatar_url"
    }

    public init(login: String, name: String? = nil, avatarURL: String? = nil) {
        self.login = login
        self.name = name
        self.avatarURL = avatarURL
    }
}
