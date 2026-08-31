import Foundation
import Observation
import SwiftUI

/// What the pill is currently saying. Drives colour, glyph and visibility.
public enum IslandMood: Sendable, Equatable {
    case idle
    case running
    case failed
    case success
    /// Something is parked waiting for a person to approve it.
    case approval
    case error

    /// Worst-status-wins ordering: a failure outranks a run, a run outranks a
    /// success.
    ///
    /// `approval` sits **above** `failed`, which looks wrong for about a
    /// second. A failure has already happened and will not change no matter how
    /// long you look at it; an approval is the only state on the island where
    /// something is waiting on *you*, and where not noticing has a cost —
    /// GitHub cancels an unapproved deployment after thirty days. So when a
    /// repository has both, the island leads with the one you can act on.
    var rank: Int {
        switch self {
        case .idle: return 0
        case .success: return 1
        case .running: return 2
        case .failed: return 3
        case .approval: return 4
        case .error: return 5
        }
    }
}

/// Bridges the `RunMonitor` actor to SwiftUI.
@MainActor
@Observable
public final class IslandModel {
    public private(set) var state = MonitorState()
    public var isExpanded = false

    /// Ticks each second so elapsed times count up between polls.
    public private(set) var now = Date()

    /// The monitor's change signature for `state`, computed once per update.
    ///
    /// The island animates content changes off this string, and
    /// `MonitorState.signature` is not cheap: it walks every run, then every
    /// job and every running step inside it, allocating and sorting arrays and
    /// building strings as it goes. Read straight from `state` inside `body`,
    /// SwiftUI rebuilt the whole thing on every pass — once a second at rest,
    /// and again on every hover. `state` only ever changes in `apply(_:)`, and
    /// the monitor has already computed this to decide whether to emit at all,
    /// so the answer is kept rather than recomputed.
    public private(set) var stateSignature = ""

    /// Drives the enter/exit morph.
    public var isOnScreen = false

    /// True while the island is animating OUT.
    public var isLeaving = false

    /// How long a finished run stays visible, measured from its real finish.
    private let finishedLinger: TimeInterval = 30
    /// Failures linger longer than successes — but still expire.
    private let failedLinger: TimeInterval = 600
    /// How long a run blocked on *somebody else* stays visible.
    ///
    /// A gate somebody else has to open can sit for days — GitHub only gives
    /// up after thirty. Pinning it forever would camp the island open on
    /// something you cannot act on, so it gets an hour: long enough to be
    /// noticed, short enough not to become furniture. A run waiting on **you**
    /// is exempt, because that one you can end whenever you like.
    private let blockedLinger: TimeInterval = 3_600

    private var tickTask: Task<Void, Never>?

    /// Called whenever the set of runs the island draws changes — and therefore
    /// whenever the panel may need to appear or disappear.
    ///
    /// Event-driven on purpose. The panel used to be kept in sync by a 2 Hz poll
    /// that ran for the life of the process, which is a CPU wakeup every 500 ms
    /// on a machine with nothing on screen and the display asleep. Apple's
    /// energy guidance is no more than one wakeup per second for an idle app,
    /// so the only things that can move this — a new monitor state, the 1 s
    /// elapsed ticker (which itself runs only while runs are visible and the
    /// screen is awake), and the screen waking back up — call out here instead.
    @ObservationIgnored
    public var onDisplayChange: (@MainActor () -> Void)?

    public init() {}

    public func apply(_ newState: MonitorState) {
        state = newState
        stateSignature = newState.signature
        Haptics.runsChanged(newState.runs)
        ApprovalNotifier.runsChanged(newState.runs)
        recomputeDerivedState()
        updateTicker()
        onDisplayChange?()
    }

    // MARK: - Derived UI state

    /// Runs the island cares about right now.
    ///
    /// Stored, not computed. Everything the island draws is derived from it —
    /// `mood`, `headline`, `collapsedRuns`, `expandedDetail`, `visibleActors`,
    /// `isVisible`, `settleProgress` — and SwiftUI reads those several times
    /// per body pass, so a computed version ran this filter and sort about ten
    /// times per redraw, once a second, for every visible run. It depends only
    /// on `state` and `now`, and both change in exactly two places:
    /// `apply(_:)` and the ticker. So it is recomputed there, together with
    /// every derivation that moves when it does.
    public private(set) var relevantRuns: [WorkflowRun] = []

    /// Worst status across live runs only.
    public private(set) var mood: IslandMood = .idle

    /// The run the collapsed pill describes — the worst one, newest first.
    public private(set) var headline: WorkflowRun?

    /// The lines the collapsed island draws — one per live run.
    public private(set) var collapsedRuns: [WorkflowRun] = []

    /// Distinct people behind the runs on screen, in the order they appear.
    ///
    /// Only interesting when more than one person's work is visible, which is
    /// exactly when the pill needs to say whose run it is showing.
    public private(set) var visibleActors: [String] = []

    /// Runs parked on a person, in the same order as `relevantRuns`.
    ///
    /// Stored for the reason everything else here is: the menu bar item reads
    /// it twice on every redraw and the island once per body pass, and a
    /// computed version filtered the whole list each time.
    public private(set) var blockedRuns: [WorkflowRun] = []

    /// Runs GitHub says this account can unblock.
    public private(set) var runsAwaitingMe: [WorkflowRun] = []

    /// Everything `relevantRuns` implies, in one pass.
    ///
    /// Stored for the same reason `relevantRuns` is, and the measurement that
    /// justified it applies more strongly here: `showsMultipleActors` is read
    /// once per drawn row, so a four-run pill asked for it five times per body
    /// pass and each answer allocated a `Set` per run and then scanned an array
    /// linearly. All four move with `relevantRuns` and nothing else, so they
    /// are computed where it is.
    private func recomputeDerivedState() {
        recomputeRelevantRuns()

        mood = worstMood()
        headline = relevantRuns.first { Self.mood(for: $0) == mood }
            ?? relevantRuns.first
        collapsedRuns = Array(relevantRuns.prefix(collapsedRowLimit))
        visibleActors = distinctLogins()
        blockedRuns = relevantRuns.filter(\.isBlockedOnApproval)
        runsAwaitingMe = relevantRuns.filter(\.awaitsMyApproval)
    }

    private func recomputeRelevantRuns() {
        let live = state.runs.filter { run in
            // Anything actually in flight, always.
            if run.isActive { return true }

            // A run parked on an approval is not finished — it is stopped,
            // indefinitely, waiting for a person — and `action_required`
            // carries a `finished_at` of whenever the pull request was opened,
            // so the thirty-second rule below would have discarded it before
            // it was ever drawn once.
            if run.awaitsMyApproval { return true }
            if run.isBlockedOnApproval {
                guard let since = run.finishedAt else { return true }
                return now.timeIntervalSince(since) < blockedLinger
            }

            guard let finished = run.finishedAt else { return false }
            let age = now.timeIntervalSince(finished)

            return run.status.isFailure ? age < failedLinger : age < finishedLinger
        }
        relevantRuns = live.sorted { lhs, rhs in
            // Whatever needs a human first, then whatever is moving, then
            // whatever broke — the same order the moods rank in, and for the
            // same reason.
            let lhsBlocked = lhs.isBlockedOnApproval
            let rhsBlocked = rhs.isBlockedOnApproval
            if lhsBlocked != rhsBlocked { return lhsBlocked }
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            let lhsFailed = lhs.status.isFailure
            let rhsFailed = rhs.status.isFailure
            if lhsFailed != rhsFailed { return lhsFailed }
            return (lhs.startedAt ?? .distantPast) > (rhs.startedAt ?? .distantPast)
        }
    }

    private func worstMood() -> IslandMood {
        if state.error != nil { return .error }
        var worst = IslandMood.idle
        for run in relevantRuns {
            let runMood = Self.mood(for: run)
            if runMood.rank > worst.rank { worst = runMood }
        }
        return worst
    }

    /// First-appearance order, de-duplicated through a set rather than a linear
    /// scan of everything collected so far.
    private func distinctLogins() -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for run in relevantRuns {
            for login in run.logins.sorted() where seen.insert(login).inserted {
                ordered.append(login)
            }
        }
        return ordered
    }

    /// Every run the monitor knows about, newest first.
    public var allRuns: [WorkflowRun] {
        state.runs.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    static func mood(for status: RunStatus) -> IslandMood {
        if status.isAwaitingApproval { return .approval }
        if status.isActive { return .running }
        if status.isFailure { return .failed }
        switch status {
        case .success: return .success
        default: return .idle
        }
    }

    /// The run's mood, approvals included.
    ///
    /// Separate from the status-only form because a run can be `in_progress`
    /// at the top level while one of its jobs sits on a required reviewer —
    /// the shape of every build that has reached its deploy stage. Reading the
    /// run's status alone would draw that as "building", which is exactly
    /// wrong: nothing is building, and nothing will until somebody clicks.
    static func mood(for run: WorkflowRun) -> IslandMood {
        run.isBlockedOnApproval ? .approval : mood(for: run.status)
    }

    /// Everything the headline is *not* describing.
    public var otherRuns: [WorkflowRun] {
        guard let headline else { return [] }
        return relevantRuns.filter { $0.identity != headline.identity }
    }

    /// How many runs the collapsed island shows before it stops growing.
    private let collapsedRowLimit = 4

    /// Live runs that did not fit in the collapsed island.
    public var hiddenRunCount: Int {
        max(relevantRuns.count - collapsedRowLimit, 0)
    }

    /// Runs to draw job detail for when expanded.
    public var expandedDetail: [WorkflowRun] {
        Array(relevantRuns.prefix(6))
    }

    /// True when the island is showing more than one person's runs, so rows
    /// should be labelled with who triggered them.
    public var showsMultipleActors: Bool { visibleActors.count > 1 }

    /// Whether the panel should be on screen at all.
    public var isVisible: Bool {
        // Never disappear while the user is reading it.
        if isExpanded { return true }
        if state.error != nil { return true }
        return !relevantRuns.isEmpty
    }

    /// How far through its linger window the most recent finished run is, 0...1.
    public var settleProgress: Double {
        // An approval never fades. It is not a finished run being polite about
        // getting out of the way; it is a question nobody has answered.
        guard blockedRuns.isEmpty else { return 0 }
        guard !relevantRuns.contains(where: \.isActive) else { return 0 }
        guard let finished = relevantRuns.compactMap(\.finishedAt).max() else { return 0 }

        let age = now.timeIntervalSince(finished)
        let window = relevantRuns.contains { $0.status.isFailure } ? failedLinger : finishedLinger
        let dimStart = window * 0.66
        guard age > dimStart else { return 0 }
        return min((age - dimStart) / (window - dimStart), 1)
    }

    // MARK: - Ticker

    /// True while the display is asleep or the machine is suspended.
    public private(set) var isSuspended = false

    /// Stop the elapsed-time ticker while nobody can see what it counts.
    ///
    /// The ticker is for someone watching a counter move. Nobody is watching a
    /// dark screen — and a failed run lingers for ten minutes, so without this
    /// a single failure keeps taking a wakeup a second, and a SwiftUI redraw
    /// with it, through a closed lid. The monitor already slows its polling on
    /// exactly these two notifications; this is the other half of that.
    public func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        if !suspended {
            // Time passed while the ticker was stopped, so every linger window
            // is stale — a run may have aged out entirely.
            now = Date()
            recomputeDerivedState()
        }
        updateTicker()
        onDisplayChange?()
    }

    /// Only run a 1s timer when something is actually counting, and only while
    /// there is someone to count for.
    private func updateTicker() {
        let needsTicker = !relevantRuns.isEmpty && !isSuspended
        if needsTicker {
            guard tickTask == nil else { return }
            tickTask = Task { [weak self] in
                while !Task.isCancelled {
                    // 100 ms of tolerance on a 1 s tick — Apple's guideline is at
                    // least 10% for a repeating timer — lets macOS coalesce this
                    // wakeup with others already scheduled nearby instead of
                    // bringing the CPU out of idle on its own. A tenth of a second
                    // is invisible on a counter that renders whole seconds.
                    do {
                        try await Task.sleep(for: .seconds(1), tolerance: .milliseconds(100))
                    } catch {
                        return // cancelled
                    }
                    guard let self else { return }
                    self.now = Date()
                    self.recomputeDerivedState()
                    self.onDisplayChange?()
                    if self.relevantRuns.isEmpty {
                        self.stopTicker()
                        return
                    }
                }
            }
        } else {
            now = Date()
            stopTicker()
        }
    }

    private func stopTicker() {
        tickTask?.cancel()
        tickTask = nil
    }
}

// MARK: - Formatting

enum IslandFormat {
    /// `1:24` style elapsed, or `42s` for short runs.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        guard total >= 60 else { return "\(max(total, 0))s" }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Live elapsed time for a running workflow.
    static func elapsed(_ run: WorkflowRun, now: Date) -> String? {
        if run.isActive {
            guard let startedAt = run.startedAt else { return nil }
            return duration(now.timeIntervalSince(startedAt))
        }
        guard let seconds = run.duration else { return nil }
        return duration(seconds)
    }

    /// A branch name shortened for a 520pt pill.
    static func branch(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }
}
