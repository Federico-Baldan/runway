import Foundation

/// A snapshot of everything the UI needs to draw one frame.
public struct MonitorState: Sendable, Equatable {
    /// Runs across every watched repository, already actor-filtered.
    public var runs: [WorkflowRun]
    /// The same poll's runs *before* the actor filter and the dismissals.
    ///
    /// Carried so Settings can answer "how many would each option show", which
    /// it cannot do from `runs`: those have already been narrowed by whichever
    /// option is currently selected, so filtering them again can only ever
    /// subtract. Previewing "Everyone" from "Only my runs" reported the number
    /// of my runs — the same figure as the option beside it, which is exactly
    /// the comparison the count exists to make.
    ///
    /// Nearly free to carry. The monitor is already holding this array, and an
    /// array is copy-on-write, so handing it over is a retain rather than a
    /// copy of every run. It stays out of `emitSignature` deliberately: it
    /// moves whenever anybody's run moves, which would defeat the gate.
    public var unfilteredRuns: [WorkflowRun]
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
        unfilteredRuns: [WorkflowRun] = [],
        repositories: [String] = [],
        lastUpdate: Date? = nil,
        error: String? = nil,
        isPolling: Bool = false,
        rateLimit: RateLimit = RateLimit(),
        knownActors: [String] = []
    ) {
        self.runs = runs
        self.unfilteredRuns = unfilteredRuns
        self.repositories = repositories
        self.lastUpdate = lastUpdate
        self.error = error
        self.isPolling = isPolling
        self.rateLimit = rateLimit
        self.knownActors = knownActors
        restamp()
    }

    /// Whether anything is moving, which is what the poll cadence turns on.
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

    /// True between the first and last `await` of a `pollOnce()`.
    ///
    /// An actor serialises *statements*, not calls: `pollOnce()` is awaits
    /// nearly all the way down, and every one of them is a point where a second
    /// call gets to start. There are four ways in beyond the loop — the menu's
    /// Refresh Now, waking from sleep, changing the host, changing the token —
    /// and three of them fire alongside something that was already going to
    /// poll. Waking is the clearest: `setSuspended(false)` releases the loop
    /// from its two-minute cadence at the same instant the delegate calls
    /// `refreshNow()`, so the machine came back from a lid close and asked
    /// GitHub about every watched repository twice, in parallel, on a budget
    /// this whole file exists to protect. The second poll costs a full round of
    /// requests, a full round of decodes, and a rate limit it may or may not
    /// have — and it can only ever produce the answer the first one is already
    /// on its way back with.
    ///
    /// Coalesced rather than queued: a poll takes seconds, so a refresh that
    /// arrives mid-flight is answered by the flight already in progress.
    private var isPollInFlight = false

    /// A refresh that arrived while a poll was already running, owed as soon as
    /// that one finishes. See `refreshNow()`.
    private var pendingRefresh = false

    private var continuations: [UUID: AsyncStream<MonitorState>.Continuation] = [:]

    // MARK: Configuration

    private var repoScope: RepoScope = .recent
    private var repoLimit = 20
    private var selectedOrganizations: Set<String> = []
    private var explicitRepositories: [String] = []
    private var actorScope: ActorScope = .me
    /// Let a colleague's deploy through the actor filter when it is parked on
    /// this account's review. Off unless the user asks for it — see
    /// `Preferences.approvalsFromOthers`.
    private var includeApprovalsFromOthers = false
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

    /// Review history, keyed the same way — and unlike the two above, this one
    /// is an answer rather than a fallback.
    ///
    /// A run is only ever asked about once. The endpoint is asked exclusively
    /// about runs that have already **finished**, and a finished run's review
    /// history is immutable, so a second request could only ever return what is
    /// already here. An entry therefore doubles as the "already asked" marker,
    /// empty array included: a failed run with no reviews at all is a run that
    /// simply broke, and re-asking it every five seconds for the ten minutes it
    /// lingers on the island is the exact cost this records to avoid.
    private var reviewCache: [String: [DeploymentReview]] = [:]

    /// Runs the user has taken off the island by hand.
    ///
    /// Held here rather than filtered in the view so that everything reading a
    /// `MonitorState` — the island, the menu bar item, the notifier — agrees
    /// about what is on screen. Seeded from `Preferences` at launch and written
    /// back through `onDismissedChange`; see `DismissedRuns`.
    private var dismissed: Set<String> = []

    /// Called when `dismissed` changes, so the choice outlives the launch.
    private var onDismissedChange: (@Sendable (Set<String>) -> Void)?

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
        approvalsFromOthers: Bool,
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
        self.includeApprovalsFromOthers = approvalsFromOthers
        if let currentUser { self.currentUser = currentUser }

        if repoConfigChanged {
            repoListFetchedAt = nil
            watched = []
            configurationGeneration &+= 1
        }
        // Re-apply to what is already on screen, so a change in Settings shows
        // up immediately instead of at the next poll. Through `visibleRuns` and
        // not `activeFilter.apply` alone: the approval opt-in is part of what
        // "visible" means, and a toggle that did nothing until the next poll
        // would read as a toggle that does not work.
        //
        // Turning it *off* is exact — those runs are simply dropped. Turning it
        // *on* can only surface the ones already known to be awaiting this
        // account, since a poll with the setting off never asked for anybody
        // else's pending deployments. The next poll fills the rest in.
        state.runs = Self.visibleRuns(
            from: unfilteredRuns,
            filter: activeFilter,
            approvalsFromOthers: includeApprovalsFromOthers,
            dismissed: dismissed
        )
        state.unfilteredRuns = unfilteredRuns
        // `force`, for the same reason `reapplyVisibility` forces: a
        // configuration change is a state change the emit gate cannot see.
        //
        // `emitSignature` is built from the runs, the repository count, the
        // known actors, the rate limit and whether the loop is running — and a
        // filter change need move none of them. Swapping "Only my runs" for a
        // one-name list resolves to the same runs; on an account with nothing
        // building, every filter resolves to none at all. So the gate held the
        // frame, no state reached the main actor, and nothing downstream was
        // told anything had happened.
        //
        // That is invisible on the island, which draws runs and had none to
        // redraw. It is not invisible in the menu bar, whose scope line reads
        // the filter out of `Preferences` directly — so it went on naming
        // whoever it was built with until some unrelated poll happened to move
        // the run count. See `StatusItemController.lastActorScope`.
        emitIfChanged(force: true)
    }

    // MARK: - Dismissal

    /// Seed the set of runs the user has taken off the island, and say where to
    /// write changes to it.
    ///
    /// Called once at launch with whatever `DismissedRuns` restored.
    public func adoptDismissed(
        _ identities: Set<String>,
        onChange: @escaping @Sendable (Set<String>) -> Void
    ) {
        dismissed = identities
        onDismissedChange = onChange
        reapplyVisibility()
    }

    /// Take one run off the island.
    ///
    /// Keyed on `identity`, which carries the **attempt** — so dismissing a
    /// failed deploy and then re-running it puts the new attempt straight back.
    /// That is the intended behaviour and not a leak: the thing being dismissed
    /// is a result, and a re-run is a different result.
    ///
    /// Local only. Nothing is sent to GitHub, the run is untouched there, and
    /// `restoreDismissed()` brings every one of them back.
    public func dismiss(_ identity: String) {
        guard dismissed.insert(identity).inserted else { return }
        onDismissedChange?(dismissed)
        reapplyVisibility()
    }

    /// Put every dismissed run back.
    public func restoreDismissed() {
        guard !dismissed.isEmpty else { return }
        dismissed = []
        onDismissedChange?(dismissed)
        reapplyVisibility()
    }

    /// Re-derive what is on screen from what the last poll collected.
    ///
    /// `force`, because a dismissal is the one state change the emit gate
    /// cannot see: removing a run leaves `runs` shorter but every remaining
    /// signature identical, and on a single-run island the whole set can empty
    /// without the *rate limit* or the *repository count* moving either. The
    /// gate would hold the frame and the click would appear to do nothing.
    private func reapplyVisibility() {
        state.runs = Self.visibleRuns(
            from: unfilteredRuns,
            filter: activeFilter,
            approvalsFromOthers: includeApprovalsFromOthers,
            dismissed: dismissed
        )
        state.unfilteredRuns = unfilteredRuns
        emitIfChanged(force: true)
    }

    /// Drop the token-scoped caches. Runs when the token changes.
    ///
    /// `reviewCache` goes with the other two, and it is the one that could not
    /// be left behind. The other caches are stale detail that the next poll
    /// overwrites; this one is an *answer*, and an entry doubles as the
    /// "already asked" marker — including the empty one written when the
    /// endpoint refuses. A token that cannot see a repository's environments
    /// gets a 403 there and caches `[]` for that run forever, so a token
    /// swapped for one that *can* see them would still draw the deploy
    /// somebody turned down as the red failure GitHub calls it, for as long as
    /// the run stayed on screen. Nothing else would ever ask again.
    ///
    /// The backoff goes too. A count built up while the old token was failing
    /// is not evidence about the new one, and leaving it puts the first poll
    /// after the fix up to five minutes away.
    public func resetForNewToken() async {
        await client.invalidateCache()
        jobCache.removeAll()
        approvalCache.removeAll()
        reviewCache.removeAll()
        failureCount = 0
        watched = []
        configurationGeneration &+= 1
        repoListFetchedAt = nil
        currentUser = nil
        unfilteredRuns = []
        state = MonitorState(isPolling: state.isPolling)
        emitIfChanged(force: true)
    }

    /// Point the monitor at a different GitHub instance.
    ///
    /// A full reset, not a reconfiguration. Everything the monitor is holding —
    /// run ids, repository names, job detail, review history, the discovery
    /// cache, the ETags underneath all of it — belongs to the server that
    /// issued it, and none of it means anything on another one. Which is the
    /// same argument `resetForNewToken` makes about a token, only more so, so
    /// this is that plus the URL.
    public func setBaseURL(_ url: URL) async {
        await client.setBaseURL(url)
        await resetForNewToken()
    }

    public func refreshNow() async {
        // Deferred rather than dropped when one is already running.
        //
        // Coalescing onto the flight in progress is right when its answer will
        // do, and three of the four callers invalidate everything first: a new
        // token, a new host and a scope change all bump
        // `configurationGeneration`, which makes the in-flight poll discard its
        // own results on the way out. Dropping the refresh as well left nothing
        // to write the new answer, so the island sat on whatever it had until
        // the loop's next tick — fifteen seconds with nothing building, two
        // minutes if the screen had just slept, and up to five if a backoff was
        // in play. Storing a token and watching nothing happen is exactly the
        // moment somebody concludes the token did not work.
        guard !isPollInFlight else {
            pendingRefresh = true
            return
        }
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
            // Pay off a refresh that arrived mid-poll before going back to
            // sleep. This is the only place that can: `refreshNow` had to stand
            // down to keep one poll in flight, and the poll it stood down for
            // may have thrown its own results away.
            if pendingRefresh, !Task.isCancelled {
                pendingRefresh = false
                await pollOnce()
            }
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
        // One poll at a time — see `isPollInFlight`. Set and cleared without an
        // `await` between them and the `guard`, so no second caller can slip
        // past on the strength of a stale read.
        guard !isPollInFlight else { return }
        isPollInFlight = true
        defer { isPollInFlight = false }

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
            // Snapshotted beside the filter, not read at the point of use.
            // Both describe one configuration, and `configure(_:)` can land on
            // this actor at any `await` below — reading one live and the other
            // from a snapshot would let a poll fetch under the new setting and
            // decide under the old one.
            let approvalsFromOthers = includeApprovalsFromOthers

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
            // Plus, only when the user has asked for it, the runs the filter
            // would drop that are nonetheless waiting on *this* account — see
            // `deploymentsAwaitingMe`.
            let mine = filter.apply(collected)
            let mineIdentities = Set(mine.map(\.identity))
            let candidates = Self.deploymentsAwaitingMe(
                in: collected,
                excluding: mineIdentities,
                enabled: approvalsFromOthers
            )
            let detailedRuns = try await attachJobs(to: mine + candidates)
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
            // Decided against the settings as they are *now*, not against the
            // snapshot this poll fetched under. A poll is seconds long and a
            // click in Settings is instant; writing the snapshot's answer here
            // would put the old scope's runs back for one cycle, which is the
            // flicker `generation` exists to prevent one level up.
            state.runs = Self.visibleRuns(
                from: unfilteredRuns,
                filter: activeFilter,
                approvalsFromOthers: includeApprovalsFromOthers,
                dismissed: dismissed
            )
            state.unfilteredRuns = unfilteredRuns
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
            // retried on a backoff curve — it will never start working, and
            // repeating it is free. A response this client could not decode is
            // neither of those things: it already cost a request. See
            // `GitHubError.warrantsBackoff` for why that is a separate question
            // from `isRetryable`, which two other call sites read differently.
            failureCount = error.warrantsBackoff ? failureCount + 1 : 0
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

        watched = Self.watchList(for: repositories, carryingOver: watched)
        repoListFetchedAt = Date()
    }

    /// The watch list for a freshly discovered set of repositories, carrying
    /// forward what the previous one had learned.
    ///
    /// Split out for the reason `merged` and `interval` are: it is a decision
    /// with an answer worth asserting, and asserting it needs neither an actor
    /// nor a network. `spike/RequestGateVerify.swift` runs it.
    static func watchList(
        for repositories: [Repository],
        carryingOver watched: [WatchedRepo]
    ) -> [WatchedRepo] {
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
        // Case-insensitively, because GitHub is. `acme/api` and `acme/API` are
        // one repository there and were two here, which is the whole bug this
        // paragraph is about rather than a nicety: both got polled, so the
        // request that was supposed to be de-duplicated was spent twice a
        // cycle; and `fetchRuns` stamps the *configured* spelling onto every
        // run it returns, so one build came back as `acme/api#41/1` and
        // `acme/API#41/1` — two identities, two rows on the island for one run,
        // and two `ForEach` entries carrying the same `WorkflowRun.id`, which
        // is GitHub's run number and identical across both.
        //
        // Only the key is folded. `fullName` keeps whatever spelling it
        // arrived with, because that is what goes in the URL, and GitHub does
        // not mind either.
        var seen = Set<String>()
        return repositories.compactMap { repository in
            guard seen.insert(repository.fullName.lowercased()).inserted else { return nil }
            return previous[repository.fullName]
                ?? WatchedRepo(fullName: repository.fullName)
        }
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

    /// What the island should show, out of everything the poll knows about.
    ///
    /// One function so `configure(_:)`'s immediate re-apply and the end of a
    /// poll can never disagree about what the settings mean — they used to,
    /// and the visible symptom was a colleague's approval that appeared on a
    /// poll and vanished the next time any unrelated setting was touched.
    ///
    /// A candidate only earns its place if GitHub actually named this account
    /// as able to approve it: `deploymentsAwaitingMe` fetches on the weaker
    /// test — `status == .waiting` is all that is known before the request —
    /// and the ones that come back addressed to somebody else are dropped here
    /// rather than shown as another person's problem.
    static func visibleRuns(
        from runs: [WorkflowRun],
        filter: ActorFilter,
        approvalsFromOthers: Bool,
        dismissed: Set<String> = []
    ) -> [WorkflowRun] {
        // First, and above every other rule here. A dismissal is the user
        // saying "not this one" about a specific run, which outranks any
        // setting that would otherwise put it back — including the approval
        // opt-in below, whose whole job is to surface runs the filter hid.
        let runs = dismissed.isEmpty
            ? runs
            : runs.filter { !dismissed.contains($0.identity) }
        guard !filter.isEveryone else { return runs }
        let mine = filter.apply(runs)
        guard approvalsFromOthers else { return mine }
        let mineIdentities = Set(mine.map(\.identity))
        return mine + runs.filter {
            !mineIdentities.contains($0.identity) && $0.awaitsMyApproval
        }
    }

    /// Runs the "whose runs" filter would hide that are nonetheless waiting on
    /// this account to approve them.
    ///
    /// **Opt-in, and off by default.** The argument for it is that the filter
    /// answers *whose work is this*, and for a colleague's deploy parked on you
    /// that is the wrong question — you are the one holding it up. That reads
    /// well on a two-person repository and falls apart inside a company: an
    /// environment guarded by a team you belong to makes GitHub answer
    /// `current_user_can_approve: true` for *everybody's* deploy, so "Only my
    /// runs" filled with colleagues' pipelines and there was no setting that
    /// would stop it. A filter the app overrules is not a filter, so this now
    /// happens only when `Preferences.approvalsFromOthers` says so.
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
        enabled: Bool,
        limit: Int = 5
    ) -> [WorkflowRun] {
        guard enabled else { return [] }
        return runs
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

    /// Should this failed run cost one request to find out whether it failed at
    /// all?
    ///
    /// A deployment somebody turned down arrives here as `conclusion:
    /// "failure"`, identical in the runs list to a build that fell over, and
    /// the only endpoint that can tell them apart is
    /// `/actions/runs/{id}/approvals`. Asking it about every failure would put
    /// a request on every red run on the island for the ten minutes it lingers,
    /// which is the trap `shouldFetchJobs` and `shouldFetchApprovals` both
    /// exist to avoid — so this asks once, per run, ever, and only for the two
    /// shapes a rejection can actually arrive in:
    ///
    ///  * **The jobs are known.** Then the tell is exact: a gate that was
    ///    turned down leaves a job that is red with *no steps at all*, because
    ///    nothing inside it ever ran. Every ordinary failure has the steps that
    ///    failed, so nothing else in a normal poll matches this.
    ///  * **The jobs are not known**, which happens on a cold start — a run
    ///    that failed before the app opened is past `shouldFetchJobs`'s
    ///    two-minute window but still inside the ten minutes the island shows
    ///    failures for. There is nothing to test against, so it falls back to
    ///    the weakest honest question: does this run look like it deploys
    ///    anywhere? Only a run with an environment can have been rejected, and
    ///    `deployTarget` is already stamped from names the poll has in hand.
    ///
    /// `alreadyAsked` is what makes the arithmetic hold. Both branches describe
    /// a *finished* run, whose review history cannot change again, so a second
    /// request could only ever return the first one's answer.
    static func shouldFetchReviewHistory(
        for run: WorkflowRun,
        alreadyAsked: Bool
    ) -> Bool {
        guard !alreadyAsked, run.status == .failure else { return false }
        if !run.jobs.isEmpty {
            return run.jobs.contains { $0.status == .failure && $0.steps.isEmpty }
        }
        return run.deployTarget != nil
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
            // Before the review history, which reads `deployTarget` on the cold
            // path, and after the jobs, which are what the target is mostly
            // derived from: a run parked on a gate has GitHub's own name for
            // the environment in its pending deployments, and everything else
            // has to be read off the job and step names that have just arrived.
            copy.stampDeployTarget()
            copy.reviews = await reviewHistory(for: copy)
            // Last of all, because it overwrites `status`, and every gate above
            // wants to see the status GitHub actually sent.
            copy.stampRejection()
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

    /// Who already answered this run's deployment gates, or nothing at all.
    ///
    /// Never throws, for the same reason `pendingDeployments(for:)` does not:
    /// this is a *correction* to a run the island is already drawing, and a
    /// deploy that was rejected is at worst drawn as the failure GitHub calls
    /// it — which is exactly what happened before this existed. Taking out
    /// every other repository's runs to relabel one of them would be a bad
    /// trade.
    ///
    /// A refusal is cached as an empty history all the same. The endpoint can
    /// 403 on a repository whose environments the token cannot see while
    /// `/actions/runs` on the same repository answers 200, and that refusal
    /// will not change on the next tick either.
    private func reviewHistory(for run: WorkflowRun) async -> [DeploymentReview] {
        if let cached = reviewCache[run.identity] { return cached }
        guard Self.shouldFetchReviewHistory(for: run, alreadyAsked: false) else { return [] }
        do {
            let response = try await client.fetchReviewHistory(
                repository: run.repository,
                runID: run.id
            )
            reviewCache[run.identity] = response.value
            return response.value
        } catch let error as GitHubError where error.isRetryable {
            // The network being down is not an answer. Leave the slot empty so
            // the next poll asks again.
            return []
        } catch {
            reviewCache[run.identity] = []
            return []
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
        reviewCache = reviewCache.filter { identities.contains($0.key) }
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
