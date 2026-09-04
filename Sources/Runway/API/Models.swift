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

    /// A person was asked, and said no.
    ///
    /// **Never decoded**, because GitHub has no such conclusion. A deployment a
    /// required reviewer turns down is reported as `conclusion: "failure"` —
    /// the API being literal, since the job never ran — and that is wrong about
    /// the only thing anybody wants to know from across the room, which is
    /// whether something *broke*. Nothing broke. Somebody decided.
    ///
    /// The truth is one request away, on
    /// `/actions/runs/{id}/approvals`, where the same rejection reads
    /// `state: "rejected"` with the reviewer and their comment attached.
    /// `RunMonitor` fetches it for the runs that look like this, and
    /// `WorkflowRun.stampRejection()` puts this case here in place of
    /// `.failure` — the same stamping the repository and the deploy target get,
    /// and for the same reason: the run payload alone cannot answer it.
    case rejected

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

    /// The `status` / `conclusion` pair GitHub would have sent for this value.
    ///
    /// The inverse of `resolve(status:conclusion:)`, and the reason the encoders
    /// below are not one line shorter. `Codable` here has to be symmetric or it
    /// is a trap: every decoder in this file reads GitHub's two-field
    /// vocabulary, so an encoder writing `rawValue` under `status` produced JSON
    /// its own decoder read back as `.unknown` — a round trip that quietly
    /// forgot how every finished run ended. Nothing encodes a run today; the
    /// point is that nothing can start to and be wrong about all of them.
    ///
    /// `.rejected` is the one case with no wire form of its own, because it has
    /// none at GitHub either: it is a stamp `stampRejection()` applies on top of
    /// a payload that says `failure`, from a review history that arrives in a
    /// different response and is not part of what any of these encoders write.
    /// So it encodes as the `failure` GitHub actually sent — losing exactly the
    /// stamp that was never in the payload to begin with, rather than losing the
    /// conclusion underneath it as well.
    public var wireValues: (status: String, conclusion: String?) {
        switch self {
        case .queued: return ("queued", nil)
        case .inProgress: return ("in_progress", nil)
        case .waiting: return ("waiting", nil)
        case .requested: return ("requested", nil)
        case .pending: return ("pending", nil)
        case .success: return ("completed", "success")
        case .failure, .rejected: return ("completed", "failure")
        case .cancelled: return ("completed", "cancelled")
        case .skipped: return ("completed", "skipped")
        case .neutral: return ("completed", "neutral")
        case .timedOut: return ("completed", "timed_out")
        case .actionRequired: return ("completed", "action_required")
        case .startupFailure: return ("completed", "startup_failure")
        case .stale: return ("completed", "stale")
        // A pair `resolve` did not recognise. `completed` with no conclusion is
        // the shape it answers `.unknown` for, so this is the one value that
        // round-trips by saying nothing.
        case .unknown: return ("completed", nil)
        }
    }

    /// Active means "this run is going somewhere" — poll fast.
    public var isActive: Bool {
        switch self {
        case .queued, .inProgress, .waiting, .requested, .pending:
            return true
        case .success, .failure, .cancelled, .skipped, .neutral, .timedOut,
             .actionRequired, .startupFailure, .stale, .rejected, .unknown:
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
             .startupFailure, .stale, .neutral, .rejected:
            return true
        case .actionRequired, .queued, .inProgress, .waiting, .requested,
             .pending, .unknown:
            return false
        }
    }

    /// Anything a human would read as "this broke".
    ///
    /// `.rejected` is deliberately **not** here, and it is the reason the case
    /// exists. GitHub calls a turned-down deployment a failure; a person who
    /// turned it down themselves five minutes ago does not, and every red thing
    /// this app draws is a claim that somebody needs to go and look at it. A
    /// rejection has already been looked at. It is a decision, so it settles
    /// next to `.cancelled` — quiet, finished, nobody's problem.
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
        let wire = status.wireValues
        try container.encode(wire.status, forKey: .status)
        try container.encodeIfPresent(wire.conclusion, forKey: .conclusion)
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
    /// Settable only from inside the module, for the one thing the payload
    /// cannot say on its own — see `markRejected()`.
    public private(set) var status: RunStatus
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
        let wire = status.wireValues
        try container.encode(wire.status, forKey: .status)
        try container.encodeIfPresent(wire.conclusion, forKey: .conclusion)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encodeIfPresent(htmlURL, forKey: .htmlURL)
        try container.encode(steps, forKey: .steps)
    }

    /// Re-read this job as a rejection rather than a failure.
    ///
    /// Only ever called on a job inside a run whose review history says
    /// `rejected`, and only when the job **failed with no steps at all** —
    /// which is the exact shape of a deployment gate that was turned down: the
    /// job exists, it is red, and nothing inside it ever ran. A job in the same
    /// run that failed with steps behind it broke for its own reasons and keeps
    /// its cross.
    mutating func markRejected() {
        guard status == .failure, steps.isEmpty else { return }
        status = .rejected
    }

    /// Steps still executing.
    public var runningSteps: [Step] { steps.filter { $0.status == .inProgress } }

    /// The first step still executing, for the rows that print one name.
    ///
    /// The same fix `WorkflowRun.firstRunningJob` already carries, one level
    /// further down and missed when that one was made: `runningSteps.first`
    /// filters the whole step list and then throws away all but its head. A job
    /// in a real workflow has twenty or thirty steps, `RunLine` asks for this
    /// twice per run — once for the label, once for the `.help` text, which is
    /// a modifier argument and so is built whether or not anybody hovers — and
    /// the collapsed island redraws once a second for as long as anything is
    /// running.
    public var firstRunningStep: Step? { steps.first { $0.status == .inProgress } }

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
    /// The fused status. Settable only from inside the module, and only by
    /// `stampRejection()` — see `RunStatus.rejected`.
    public private(set) var status: RunStatus
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

    /// Who has already answered the deployment question, and how.
    ///
    /// The counterpart to `pendingDeployments`, from
    /// `/actions/runs/{id}/approvals`: that one is the reviews still owed, this
    /// one is the reviews given. Stamped, not decoded, and — like the pending
    /// list — asked for only when the run's own shape says it is worth a
    /// request. See `RunMonitor.shouldFetchReviewHistory`.
    ///
    /// It exists for one answer the rest of the API refuses to give: whether a
    /// red run is red because it broke or because somebody said no.
    public var reviews: [DeploymentReview] = []

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
        pendingDeployments: [PendingDeployment] = [],
        reviews: [DeploymentReview] = []
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
        self.reviews = reviews
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
        let wire = status.wireValues
        try container.encode(wire.status, forKey: .status)
        try container.encodeIfPresent(wire.conclusion, forKey: .conclusion)
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

    /// Re-read a GitHub "failure" as the rejection it actually was.
    ///
    /// Called once the review history has landed, and a no-op for every run
    /// that has none — which is nearly all of them. Three guards, each of them
    /// a way this could otherwise paint a real breakage as somebody's decision:
    ///
    ///  * The run must be `.failure` exactly — the one conclusion GitHub uses
    ///    for a rejection. A timeout or a startup failure is also `isFailure`
    ///    and is also, unambiguously, something that broke.
    ///  * Somebody must actually have rejected something.
    ///  * **And the jobs, once known, must corroborate it.** This is the guard
    ///    that matters. The endpoint is keyed on the run *id*, not the attempt,
    ///    so a run rejected on attempt 1 and re-run into a genuine terraform
    ///    failure on attempt 2 still answers `rejected` — and calling that a
    ///    rejection would hide a real broken deploy behind a grey glyph. A gate
    ///    that was turned down leaves a job that is red with **no steps at
    ///    all**, because nothing in it ever ran; a job that broke has the steps
    ///    that broke. Requiring one of the former is what separates the two.
    ///
    /// Jobs with no detail yet are the one exception: a run whose jobs have not
    /// been fetched has nothing to corroborate with, and the rejection is still
    /// the better answer than a red cross.
    mutating func stampRejection() {
        guard status == .failure else { return }
        guard reviews.contains(where: { $0.state == .rejected }) else { return }
        if !jobs.isEmpty {
            guard jobs.contains(where: { $0.status == .failure && $0.steps.isEmpty })
            else { return }
        }
        status = .rejected
        for index in jobs.indices { jobs[index].markRejected() }
    }

    /// `stampRejection()` as a chainable copy, for building fixtures.
    func stampingRejection() -> WorkflowRun {
        var copy = self
        copy.stampRejection()
        return copy
    }

    /// The rejection this run is being drawn as, for the words hanging off it.
    ///
    /// The **last** one in the order GitHub returned. The review objects carry
    /// no timestamp of their own — `state`, `user`, `comment` and the
    /// environments, and that is the whole schema — so on the rare run with
    /// more than one rejection in its history this is the response's ordering
    /// being trusted for a name in a tooltip, and nothing more. Which run is
    /// rejected has already been decided above, on evidence that does not
    /// depend on it.
    public var decisiveReview: DeploymentReview? {
        reviews.last { $0.state == .rejected } ?? reviews.last
    }

    /// The login of whoever turned this deployment down.
    public var rejectedBy: String? {
        guard status == .rejected else { return nil }
        return decisiveReview?.user?.login
    }

    /// What the reviewer typed in the box, when they typed anything.
    public var rejectionComment: String? {
        guard status == .rejected,
              let comment = decisiveReview?.comment,
              !comment.isEmpty else { return nil }
        return comment
    }

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
        if runAttempt > 1 { return true }
        // Both, or neither. The old form compared `actor?.login` to
        // `triggeringActor?.login` through the optionals, so a run that carries
        // a triggering actor and no actor at all compared nil against a name,
        // came out unequal, and was drawn with the re-run arrow on its first
        // attempt. Two different people is the claim; one person and a missing
        // field is not evidence of it.
        guard let actor, let triggeringActor else { return false }
        return actor.login != triggeringActor.login
    }

    public var jobList: [Job] { jobs }
    public var runningJobs: [Job] { jobs.filter { $0.status.isActive } }

    /// The first job still going, for the row that prints one name.
    ///
    /// `runningJobs.first` was doing this by filtering the whole list and then
    /// discarding all but its head — an array allocation per run, on every body
    /// pass of a view that redraws once a second.
    /// In progress first, and only then merely active.
    ///
    /// `isActive` is the poll cadence's question — is this run going anywhere —
    /// and it says yes to `queued`, `pending`, `requested` and `waiting`. This
    /// is a different question: which job to *name*. Asking the first one
    /// answered "the first job that has not finished", and on a matrix build
    /// those are not the same job. Every job in a matrix is created queued, and
    /// runners pick them up in whatever order they free up — so a run with
    /// `[shard-1 queued, shard-2 in progress]` printed `shard-1`, which had not
    /// started, while the machine was busy with `shard-2`.
    ///
    /// The fallback is what keeps a run that is entirely queued from printing
    /// nothing at all: waiting for a runner is worth saying, it just should not
    /// outrank work actually happening.
    public var firstRunningJob: Job? {
        jobs.first { $0.status == .inProgress } ?? jobs.first { $0.status.isActive }
    }

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
        // The decisive review, not the whole history. A rejection already moves
        // `status`, so this is here for the *words* hanging off it — who said
        // no, and what they typed — which arrive in the same response and would
        // otherwise reach a tooltip nobody redrew.
        let reviewPart = decisiveReview
            .map { "\($0.state.rawValue):\($0.user?.login ?? "")" } ?? ""
        // The target moves when the jobs land, and again if a gate turns a
        // guess read off a job name into the name GitHub actually uses.
        let environmentPart = deployTarget.map { "\($0.name):\($0.tier.rawValue)" } ?? ""
        return "\(identity)|\(status.rawValue)|\(jobPart)|\(stepPart)"
            + "|\(approvalPart)|\(environmentPart)|\(reviewPart)"
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
