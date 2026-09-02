import Foundation

/// A snapshot of everything the UI needs to draw one frame.
public struct MonitorState: Sendable, Equatable {
    /// Runs across every watched repository, already actor-filtered.
    public var runs: [WorkflowRun]
    /// Repositories currently being polled.
    public var repositories: [String]
    public var lastUpdate: Date?
    public var error: String?
    public var isPolling: Bool
    public var rateLimit: RateLimit
    /// Logins seen in the last poll, for the "specific people" picker.
    public var knownActors: [String]

    public init(
        runs: [WorkflowRun] = [],
        repositories: [String] = [],
        lastUpdate: Date? = nil,
        error: String? = nil,
        isPolling: Bool = false,
        rateLimit: RateLimit = RateLimit(),
        knownActors: [String] = []
    ) {
        self.runs = runs
        self.repositories = repositories
        self.lastUpdate = lastUpdate
        self.error = error
        self.isPolling = isPolling
        self.rateLimit = rateLimit
        self.knownActors = knownActors
        restamp()
    }

    public var activeRuns: [WorkflowRun] { runs.filter(\.isActive) }
    public var failedRuns: [WorkflowRun] { runs.filter { $0.status.isFailure } }
    public var hasActiveRun: Bool { runs.contains(where: \.isActive) }

    /// Combined change signature over the runs and the error — everything whose
    /// *shape* on the island can change.
    ///
    /// Stored rather than computed, because it is not cheap: it walks every
    /// run, then every job and every running step inside it, sorting and
    /// joining as it goes. Two places need the same answer for the same
    /// snapshot — the monitor, to decide whether the state is worth emitting,
    /// and `IslandModel`, to animate content changes off it — and both used to
    /// compute it separately, so every poll paid for the walk twice.
    public private(set) var signature = ""

    /// Recompute `signature` after `runs` or `error` were changed in place.
    public mutating func restamp() {
        let body = runs.map(\.signature).sorted().joined(separator: ";")
        signature = "\(body)|err:\(error ?? "")"
    }

    /// Everything a consumer *draws*, which is wider than what the island
    /// animates off.
    ///
    /// The island keys its content animation on `signature` alone, and rightly
    /// so — nothing else moves the pill. But the menu bar prints the repository
    /// count, and Settings prints the rate-limit budget, the cache hit rate and
    /// the list of logins the actor picker suggests. None of those moves a run
    /// signature, so gating the emit on `signature` froze all of them for as
    /// long as the run set held still — which, on an account with nothing
    /// building, is nearly always.
    ///
    /// `lastUpdate` is deliberately left out: it moves on every single poll and
    /// would defeat the gate entirely. `rateLimit.remaining` is the right proxy
    /// for "this poll actually cost something", since a 304 does not decrement
    /// it — so a fully cached poll still emits nothing.
    var emitSignature: String {
        "\(signature)|repos:\(repositories.count)|actors:\(knownActors.count)"
            + "|rate:\(rateLimit.remaining)/\(rateLimit.limit)|polling:\(isPolling)"
    }
}

/// Adaptive polling engine.
///
/// Structurally the same loop as the GitLab original, but the shape of the work
/// per tick is different and that difference drives the whole design. GitLab
/// answered "what is running anywhere I can see" in **one** GraphQL query.
/// GitHub has no such endpoint, so a tick is:
///
///   1. discover repositories (rarely — the list is cached for `repoListTTL`)
///   2. one runs request per repository        ← the expensive part
///   3. one jobs request per *interesting* run ← gated, see `shouldFetchJobs`
///
/// Three things keep that affordable: conditional requests (`ETagStore`), the
/// quiet-repo demotion in `WatchedRepo`, and only fetching job detail for runs
/// the island will actually draw.
public actor RunMonitor {
    public struct Cadence: Sendable {
        /// Something is building.
        public var active: TimeInterval = 5
        /// Nothing is building.
        public var idle: TimeInterval = 15
        /// Screen asleep or machine unattended.
        public var suspended: TimeInterval = 120
        /// Rate-limit headroom is nearly gone.
        public var conserving: TimeInterval = 60
        /// Floor on the interval while the system is in Low Power Mode.
        public var lowPower: TimeInterval = 30
        public var backoffBase: TimeInterval = 5
        public var backoffCeiling: TimeInterval = 300

        public init() {}
    }

    private let client: GitHubClient
    private var cadence: Cadence

    private var state = MonitorState()
    private var lastSignature: String?
    private var pollTask: Task<Void, Never>?

    private var failureCount = 0
    private var isSuspended = false
    private var isLowPower = false

    private var continuations: [UUID: AsyncStream<MonitorState>.Continuation] = [:]

    // MARK: Configuration

    private var repoScope: RepoScope = .recent
    private var repoLimit = 20
    private var selectedOrganizations: Set<String> = []
    private var explicitRepositories: [String] = []
    private var actorScope: ActorScope = .me
    private var watchedActors: [String] = []
    private var currentUser: String?

    // MARK: Discovery cache

    private var watched: [WatchedRepo] = []
    /// Bumped every time the watched set is invalidated, so a poll that is
    /// already in flight can tell that its results are for the previous
    /// configuration and stand down instead of writing them.
    private var configurationGeneration = 0
    private var repoListFetchedAt: Date?
    /// Repository discovery is one request and the answer barely moves, so it is
    /// re-fetched every few minutes rather than every tick.
    private let repoListTTL: TimeInterval = 300

    /// Jobs already fetched, keyed by run identity, so a finished run is not
    /// re-fetched on every tick just because it is still on screen.
    private var jobCache: [String: [Job]] = [:]

    /// Pending deployments, keyed the same way. Kept so a run that is blocked
    /// on an approval keeps its environment names between polls even if the
    /// endpoint has a bad minute — the island would otherwise flicker between
    /// "waiting for you to approve production" and a bare "waiting".
    private var approvalCache: [String: [PendingDeployment]] = [:]

    public init(client: GitHubClient = GitHubClient(), cadence: Cadence = Cadence()) {
        self.client = client
        self.cadence = cadence
    }

    deinit {
        pollTask?.cancel()
        for continuation in continuations.values { continuation.finish() }
    }

    // MARK: - Observation

    /// Each element is a complete snapshot, so an older one is worthless the
    /// moment a newer one exists. Buffering the newest single value keeps a
    /// consumer that stalls — the main actor, mid-animation — from then working
    /// through a queue of frames nobody will ever see.
    public func stateStream() -> AsyncStream<MonitorState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    public func currentState() -> MonitorState { state }

    // MARK: - Control

    public func start() {
        guard pollTask == nil else { return }
        state.isPolling = true
        pollTask = Task.detached { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        state.isPolling = false
        emitIfChanged(force: true)
    }

    public func setSuspended(_ suspended: Bool) {
        isSuspended = suspended
    }

    /// Mirror the system's Low Power Mode into the cadence.
    public func setLowPower(_ enabled: Bool) {
        isLowPower = enabled
    }

    /// Push the whole configuration in at once.
    ///
    /// Changing which repositories are watched invalidates the discovery cache;
    /// changing only who is watched does not, because the repository list is
    /// unaffected by the actor filter.
    public func configure(
        repoScope: RepoScope,
        repoLimit: Int,
        organizations: Set<String>,
        explicitRepositories: [String],
        actorScope: ActorScope,
        watchedActors: [String],
        currentUser: String?
    ) {
        let repoConfigChanged = repoScope != self.repoScope
            || repoLimit != self.repoLimit
            || organizations != self.selectedOrganizations
            || explicitRepositories != self.explicitRepositories

        self.repoScope = repoScope
        self.repoLimit = repoLimit
        self.selectedOrganizations = organizations
        self.explicitRepositories = explicitRepositories
        self.actorScope = actorScope
        self.watchedActors = watchedActors
        if let currentUser { self.currentUser = currentUser }

        if repoConfigChanged {
            repoListFetchedAt = nil
            watched = []
            configurationGeneration &+= 1
        }
        // Re-apply the actor filter to what is already on screen, so a change in
        // Settings shows up immediately instead of at the next poll.
        state.runs = activeFilter.apply(unfilteredRuns)
        emitIfChanged()
    }

    /// Drop the token-scoped caches. Runs when the token changes.
    public func resetForNewToken() async {
        await client.invalidateCache()
        jobCache.removeAll()
        approvalCache.removeAll()
        watched = []
        configurationGeneration &+= 1
        repoListFetchedAt = nil
        currentUser = nil
        unfilteredRuns = []
        state = MonitorState(isPolling: state.isPolling)
        emitIfChanged(force: true)
    }

    public func refreshNow() async {
        await pollOnce()
    }

    /// The filter the current configuration resolves to.
    private var activeFilter: ActorFilter {
        ActorFilter.resolve(scope: actorScope, watched: watchedActors, currentUser: currentUser)
    }

    // MARK: - Loop

    private func runLoop() async {
        while !Task.isCancelled {
            await pollOnce()
            let delay = nextInterval()
            do {
                // The tolerance is what lets macOS coalesce this wakeup with
                // timers other processes have already scheduled nearby, instead
                // of bringing the CPU out of idle on its own. Apple's guidance
                // is at least 10% of the interval for a repeating timer, and a
                // poll that is half a second late is indistinguishable from one
                // that is on time.
                try await Task.sleep(
                    for: .seconds(delay),
                    tolerance: .seconds(delay * 0.1)
                )
            } catch {
                return // cancelled
            }
        }
    }

    /// Last unfiltered result, so a filter change applies without a new poll.
    private var unfilteredRuns: [WorkflowRun] = []

    /// The warning for a repository list GitHub quietly shortened.
    ///
    /// `partial-results` arrives on a `200`: `/user/repos` succeeds, the
    /// unauthorized organization's repositories are simply not in it, and
    /// nothing anywhere fails. Without this the island watches the wrong set
    /// of repositories and looks perfectly healthy doing it.
    private func partialResultsWarning(_ notice: SSONotice?) -> String? {
        guard case .partialResults(let ids) = notice, !ids.isEmpty else { return nil }
        let subject = ids.count == 1 ? "one organization" : "\(ids.count) organizations"
        return "GitHub left \(subject) out of the repository list: this token is not "
            + "authorized for SAML single sign-on there."
    }

    private func pollOnce() async {
        // Which configuration this poll belongs to. Every `await` below hands
        // the actor to whoever else is waiting on it, and `configure(_:)` is
        // one call away from a click in Settings.
        let generation = configurationGeneration
        do {
            if currentUser == nil {
                currentUser = try await client.fetchAuthenticatedUser().login
            }
            try await refreshRepositoriesIfStale()

            let filter = activeFilter

            var collected: [WorkflowRun] = []
            var seenLogins = Set<String>()
            // Set when a repository is refused for SAML SSO. Held rather than
            // thrown: one unauthorized organization must not cost the poll
            // every *other* organization's runs, but it must not vanish
            // either — silence here is what made this bug unreadable.
            var ssoBlocked: String?

            // Polled off a SNAPSHOT, and the results merged back by name at the
            // end. Never `watched[index]` across an `await`.
            //
            // An actor is re-entrant: every `await` below is a point where
            // another task gets to run this actor's code, and `configure(_:)`
            // — which the Settings window calls the instant you pick a
            // different repository scope — sets `watched = []`. `for index in
            // watched.indices` had already materialised the old range, so the
            // resumption after the network call indexed an emptied array and
            // the app died on `Index out of range`. Intermittent by nature: it
            // needed a poll to be in flight at the moment of the change, which
            // on a twenty-repository account is most of the time.
            var progress = watched
            for repoIndex in progress.indices {
                guard !Task.isCancelled else { return }
                guard progress[repoIndex].shouldPoll() else { continue }

                let repo = progress[repoIndex].fullName
                let response: Conditional<WorkflowRunsPayload>
                do {
                    // Always unfiltered. `?actor=` would narrow this
                    // server-side, but it matches the push author rather than
                    // the run's actor and so cannot see a run you re-ran —
                    // see ActorFilter. A wider page costs the same single
                    // request, so take the width instead.
                    response = try await client.fetchRuns(
                        repository: repo,
                        perPage: 30
                    )
                } catch GitHubError.notFound {
                    // Renamed, deleted, or outside the token's resource owner.
                    progress[repoIndex].hasWorkflows = false
                    continue
                } catch GitHubError.forbidden {
                    // Actions disabled on this repository, or no Actions: Read
                    // for it. Either way it will never produce a run.
                    progress[repoIndex].hasWorkflows = false
                    continue
                } catch let error as GitHubError {
                    // A SAML organization refusing an unauthorized token looks
                    // identical to the case above — a 403 per repository —
                    // and used to be swallowed by it, which is how a whole
                    // organization could go missing without a word. Skip the
                    // repository like any other 403, but keep the reason.
                    guard case .singleSignOnRequired = error else { throw error }
                    progress[repoIndex].hasWorkflows = false
                    ssoBlocked = error.errorDescription
                    continue
                }

                progress[repoIndex].hasWorkflows = response.value.totalCount > 0
                for run in response.value.workflowRuns {
                    seenLogins.formUnion(run.logins)
                    collected.append(run)
                }
            }

            // The scope changed while this poll was in the air, so everything
            // it collected describes a repository set the user has already
            // moved on from. Writing it to `state` would put the old scope's
            // runs back on the island for one cycle. Drop it; the reconfigured
            // poll is already on its way.
            guard generation == configurationGeneration else { return }
            merge(polled: progress)

            // Job detail is fetched only for runs that survive the filter —
            // no point paying a request for a colleague's run that is about to
            // be discarded. The unfiltered set is still kept, so widening the
            // filter in Settings takes effect immediately rather than at the
            // next poll; those runs simply arrive without detail until then.
            //
            // Plus the runs the filter would drop that are nonetheless waiting
            // on *this* account — see `deploymentsAwaitingMe`.
            let mine = filter.apply(collected)
            let mineIdentities = Set(mine.map(\.identity))
            let candidates = Self.deploymentsAwaitingMe(in: collected, excluding: mineIdentities)
            let detailedRuns = try await attachJobs(to: mine + candidates)
            // A candidate only earns its place if GitHub actually named this
            // account as able to approve it. The rest were a request each and
            // are dropped here rather than shown as somebody else's problem.
            let visible = detailedRuns.filter {
                mineIdentities.contains($0.identity) || $0.awaitsMyApproval
            }
            // `uniquingKeysWith` rather than `uniqueKeysWithValues`, which
            // *traps* on a repeated key. Two watched entries naming the same
            // repository — `RUNWAY_REPOS="a/b,a/b"` is enough, the environment
            // list is not de-duplicated — put every one of that repo's runs in
            // `collected` twice, and the app died on its first poll. `watched`
            // is de-duplicated below as well; this is the belt to that braces,
            // because the keys are ultimately GitHub's data and a crash is a
            // bad way to find out it surprised us.
            let detailed = Dictionary(
                detailedRuns.map { ($0.identity, $0) },
                uniquingKeysWith: { _, latest in latest }
            )
            pruneJobCache(keeping: Set(collected.map(\.identity)))

            // `attachJobs` is another handful of awaits, so the same race is
            // open across it. Checked again rather than once, because this is
            // the write that actually reaches the island.
            guard generation == configurationGeneration else { return }

            failureCount = 0
            unfilteredRuns = collected.map { detailed[$0.identity] ?? $0 }
            state.runs = visible
            state.repositories = watched.map(\.fullName)
            state.knownActors = seenLogins.sorted { $0.lowercased() < $1.lowercased() }
            state.rateLimit = await client.currentRateLimit()
            state.lastUpdate = Date()
            // A poll that succeeded for most repositories still has something
            // to say if an organization was refused, or if GitHub trimmed the
            // repository list on the way in.
            let sso = await client.currentSSONotice()
            state.error = ssoBlocked ?? partialResultsWarning(sso)
        } catch let error as GitHubError {
            // A hard failure (bad token, missing permission) must not be
            // retried on a backoff curve — it will never start working.
            failureCount = error.isRetryable ? failureCount + 1 : 0
            state.error = error.errorDescription
            state.rateLimit = await client.currentRateLimit()
        } catch {
            failureCount += 1
            state.error = error.localizedDescription
            state.rateLimit = await client.currentRateLimit()
        }
        emitIfChanged()
    }

    /// Fold a finished poll's learned flags back into the live watch list.
    ///
    /// By name, never by position. The snapshot the poll worked from is by
    /// definition out of date by the time it lands — `refreshRepositoriesIfStale`
    /// may have re-ordered the list, or dropped a repository from it entirely —
    /// and a positional write-back would put one repository's "has no Actions"
    /// verdict onto another one.
    private func merge(polled: [WatchedRepo]) {
        watched = Self.merged(watched, polled: polled)
    }

    /// The merge itself, as a pure function of its inputs.
    ///
    /// Split out for the same reason `interval` is: this is the half of the
    /// re-entrancy fix that has an answer worth asserting, and asserting it
    /// needs neither an actor nor a network. `spike/ReentrancyVerify.swift`
    /// runs it against the shapes the race actually produces — a shorter list,
    /// a re-ordered one, a repository that has been dropped outright.
    static func merged(_ live: [WatchedRepo], polled: [WatchedRepo]) -> [WatchedRepo] {
        guard !polled.isEmpty else { return live }
        let learned = Dictionary(
            polled.map { ($0.fullName, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        return live.map { repo in
            guard let update = learned[repo.fullName] else { return repo }
            var merged = repo
            merged.hasWorkflows = update.hasWorkflows
            merged.skippedCycles = update.skippedCycles
            return merged
        }
    }

    /// Re-discover repositories when the cached list has aged out.
    private func refreshRepositoriesIfStale() async throws {
        if let fetchedAt = repoListFetchedAt,
           Date().timeIntervalSince(fetchedAt) < repoListTTL,
           !watched.isEmpty {
            return
        }

        let repositories = try await client.fetchRepositories(
            scope: repoScope,
            limit: repoLimit,
            organizations: selectedOrganizations,
            explicit: explicitRepositories
        )

        // Carry the learned `hasWorkflows` flag across a refresh, so a repo that
        // was demoted for having no Actions is not promoted back every 5 minutes.
        let previous = Dictionary(
            watched.map { ($0.fullName, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // De-duplicated on the way in. A repository listed twice is not an
        // error worth refusing the poll over, but polling it twice is a wasted
        // request per cycle and — until this — a trap on the duplicate run
        // identities it produced. `.explicit` takes the list verbatim from
        // Settings or `RUNWAY_REPOS`, neither of which de-duplicates.
        var seen = Set<String>()
        watched = repositories.compactMap { repository in
            guard seen.insert(repository.fullName).inserted else { return nil }
            return previous[repository.fullName]
                ?? WatchedRepo(fullName: repository.fullName)
        }
        repoListFetchedAt = Date()
    }

    /// Should this run cost a second request for its job detail?
    ///
    /// Job detail is what the expanded island draws, and it is one request per
    /// run. Fetching it for everything would roughly double the poll cost for
    /// rows nobody is looking at, so it is limited to runs that are either
    /// moving or freshly finished — the only ones the island shows.
    static func shouldFetchJobs(for run: WorkflowRun, now: Date = Date()) -> Bool {
        if run.isActive { return true }
        // A run waiting on a person is not moving and not finished. Its
        // `finished_at` is however long ago somebody opened the pull request,
        // so the two-minute window below would drop it — and it is precisely
        // the run whose job list says *which* job is blocked.
        if run.status.isAwaitingApproval { return true }
        guard let finishedAt = run.finishedAt else { return false }
        return now.timeIntervalSince(finishedAt) < 120
    }

    /// Runs the "whose runs" filter would hide that are nonetheless waiting on
    /// this account to approve them.
    ///
    /// The filter answers *whose work is this*, and for a colleague's deploy
    /// parked on you that is the wrong question — you are the one holding it
    /// up. It is the same argument the actor filter already makes for re-runs:
    /// re-running somebody else's failed deploy puts it on your island because
    /// you are now the one waiting on it. This is that, one step further.
    ///
    /// Restricted to `status == .waiting`, which is the only shape that can
    /// ever answer `current_user_can_approve`. A first-time contributor gate
    /// (`action_required`) has no pending deployments and no reviewer list, so
    /// widening this to cover it would spend a request per run per poll to
    /// learn nothing. Capped as well: a busy organization can have a lot of
    /// deploys queued behind one reviewer, and this runs before the island has
    /// any say in what it draws.
    static func deploymentsAwaitingMe(
        in runs: [WorkflowRun],
        excluding identities: Set<String>,
        limit: Int = 5
    ) -> [WorkflowRun] {
        runs
            .filter { $0.status == .waiting && !identities.contains($0.identity) }
            .prefix(limit)
            .map { $0 }
    }

    /// Should this run cost a *third* request, for its pending deployments?
    ///
    /// Only when it has already said it is waiting. The endpoint answers `[]`
    /// for every run that is not blocked, so asking speculatively would spend
    /// one request per run per poll to learn nothing — the same trap
    /// `shouldFetchJobs` exists to avoid, one level further in.
    ///
    /// Checked against the run *with its jobs attached*: a run can report
    /// `in_progress` at the top level while one of its jobs sits on
    /// `waiting`, which is exactly the shape of a build that has reached its
    /// deploy stage.
    static func shouldFetchApprovals(for run: WorkflowRun) -> Bool {
        run.status.isAwaitingApproval || run.jobs.contains { $0.status.isAwaitingApproval }
    }

    /// Attach jobs and steps to the runs that warrant them.
    private func attachJobs(to runs: [WorkflowRun]) async throws -> [WorkflowRun] {
        var result: [WorkflowRun] = []
        result.reserveCapacity(runs.count)

        for run in runs {
            var copy = run

            if Self.shouldFetchJobs(for: run) {
                do {
                    let response = try await client.fetchJobs(
                        repository: run.repository,
                        runID: run.id
                    )
                    copy.jobs = response.value
                    jobCache[run.identity] = response.value
                } catch {
                    // Detail is a nicety; a run without it still renders as a
                    // single line. Only a retryable fault — the network being
                    // down — is worth failing the whole poll for.
                    if let githubError = error as? GitHubError, githubError.isRetryable {
                        throw error
                    }
                    copy.jobs = jobCache[run.identity] ?? []
                }
            } else {
                copy.jobs = jobCache[run.identity] ?? []
            }

            copy.pendingDeployments = await pendingDeployments(for: copy)
            // Last, because it reads both of the things above: a run parked on
            // a gate has GitHub's own name for the environment in its pending
            // deployments, and everything else has to be read off the job and
            // step names that have just arrived.
            copy.stampDeployTarget()
            result.append(copy)
        }
        return result
    }

    /// The environments a blocked run is parked on, or nothing at all.
    ///
    /// Never throws. An approval is a *detail* on a run the island is already
    /// drawing correctly — `waiting` is visible with or without the
    /// environment names — and this endpoint has more ways to be refused than
    /// the others: a repository whose environments the token cannot see
    /// answers 403 while `/actions/runs` on the same repository answers 200.
    /// Failing the poll over that would take out every other repository's runs
    /// to learn the name of one environment.
    private func pendingDeployments(for run: WorkflowRun) async -> [PendingDeployment] {
        guard Self.shouldFetchApprovals(for: run) else {
            approvalCache[run.identity] = nil
            return []
        }
        do {
            let response = try await client.fetchPendingDeployments(
                repository: run.repository,
                runID: run.id
            )
            approvalCache[run.identity] = response.value
            return response.value
        } catch {
            return approvalCache[run.identity] ?? []
        }
    }

    /// Drop cached job detail for runs that have left the window.
    ///
    /// Keyed on the *unfiltered* set on purpose: pruning against what is
    /// currently visible would discard detail every time the actor filter
    /// narrowed, then re-fetch all of it the moment it widened again.
    private func pruneJobCache(keeping identities: Set<String>) {
        jobCache = jobCache.filter { identities.contains($0.key) }
        approvalCache = approvalCache.filter { identities.contains($0.key) }
    }

    /// Poll cadence for the next tick, as a pure function of its inputs.
    ///
    /// Split out from the actor so the precedence can be checked without a
    /// client, a network or a running loop — it is the kind of decision where
    /// the ordering matters and reading it is not enough to be sure:
    ///
    ///   * A retry backoff wins outright. Nothing else is worth considering
    ///     while requests are failing.
    ///   * A dark screen wins over everything else, because nobody can see the
    ///     island; there is no cadence worth paying for.
    ///   * Otherwise the interval is the normal active/idle choice raised to
    ///     whichever *floor* applies — conserving when the rate-limit budget is
    ///     nearly gone, Low Power Mode when the user has asked for less battery
    ///     use. They are floors rather than replacements so that the slowest
    ///     applicable constraint wins instead of the last one checked.
    static func interval(
        cadence: Cadence,
        failureCount: Int,
        isSuspended: Bool,
        isLowPower: Bool,
        isRateLimitTight: Bool,
        hasActiveRun: Bool
    ) -> TimeInterval {
        if failureCount > 0 {
            // 5, 10, 20, 40 … capped at 5 minutes.
            let factor = pow(2.0, Double(failureCount - 1))
            return min(cadence.backoffBase * factor, cadence.backoffCeiling)
        }
        if isSuspended { return cadence.suspended }

        var interval = hasActiveRun ? cadence.active : cadence.idle
        // Back off before GitHub has to say no. Conditional requests usually
        // keep this from ever triggering, but a large watch list on a fresh
        // ETag cache can burn through the budget quickly.
        if isRateLimitTight { interval = max(interval, cadence.conserving) }
        if isLowPower { interval = max(interval, cadence.lowPower) }
        return interval
    }

    private func nextInterval() -> TimeInterval {
        Self.interval(
            cadence: cadence,
            failureCount: failureCount,
            isSuspended: isSuspended,
            isLowPower: isLowPower,
            isRateLimitTight: state.rateLimit.isTight,
            hasActiveRun: state.hasActiveRun
        )
    }

    /// Dedupe gate: observers only wake when the signature actually moved.
    private func emitIfChanged(force: Bool = false) {
        // The one place the signature is computed. Everything downstream reads
        // the stamp rather than walking the runs again.
        state.restamp()
        let signature = state.emitSignature
        guard force || signature != lastSignature else { return }
        lastSignature = signature

        let snapshot = state
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }
}
