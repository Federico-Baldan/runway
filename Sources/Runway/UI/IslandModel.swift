import Foundation
import Observation
import SwiftUI

/// What the pill is currently saying. Drives colour, glyph and visibility.
public enum IslandMood: Sendable, Equatable {
    case idle
    case running
    case failed
    case success
    case error

    /// Worst-status-wins ordering: a failure outranks a run, a run outranks a success.
    var rank: Int {
        switch self {
        case .idle: return 0
        case .success: return 1
        case .running: return 2
        case .failed: return 3
        case .error: return 4
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

    /// Drives the enter/exit morph.
    public var isOnScreen = false

    /// True while the island is animating OUT.
    public var isLeaving = false

    /// How long a finished run stays visible, measured from its real finish.
    private let finishedLinger: TimeInterval = 30
    /// Failures linger longer than successes — but still expire.
    private let failedLinger: TimeInterval = 600

    private var tickTask: Task<Void, Never>?

    /// Called whenever the set of runs the island draws changes — and therefore
    /// whenever the panel may need to appear or disappear.
    ///
    /// Event-driven on purpose. The panel used to be kept in sync by a 2 Hz poll
    /// that ran for the life of the process, which is a CPU wakeup every 500 ms
    /// on a machine with nothing on screen and the display asleep. Apple's
    /// energy guidance is no more than one wakeup per second for an idle app,
    /// so the only two things that can move this — a new monitor state and the
    /// 1 s elapsed ticker, which itself only runs while runs are visible — call
    /// out here instead.
    @ObservationIgnored
    public var onDisplayChange: (@MainActor () -> Void)?

    public init() {}

    public func apply(_ newState: MonitorState) {
        state = newState
        Haptics.runsChanged(newState.runs)
        recomputeRelevantRuns()
        updateTicker()
        onDisplayChange?()
    }

    // MARK: - Derived UI state

    /// Runs the island cares about right now.
    ///
    /// Stored, not computed. Nearly every other property below is derived from
    /// it — `mood`, `headline`, `otherRuns`, `collapsedRuns`, `expandedDetail`,
    /// `visibleActors`, `isVisible`, `settleProgress` — and SwiftUI reads those
    /// several times per body pass, so a computed version ran this filter and
    /// sort about ten times per redraw, once a second, for every visible run.
    /// It depends only on `state` and `now`, and both change in exactly two
    /// places: `apply(_:)` and the ticker. So it is recomputed there.
    public private(set) var relevantRuns: [WorkflowRun] = []

    private func recomputeRelevantRuns() {
        let live = state.runs.filter { run in
            // Anything actually in flight, always.
            if run.isActive { return true }

            guard let finished = run.finishedAt else { return false }
            let age = now.timeIntervalSince(finished)

            return run.status.isFailure ? age < failedLinger : age < finishedLinger
        }
        relevantRuns = live.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            let lhsFailed = lhs.status.isFailure
            let rhsFailed = rhs.status.isFailure
            if lhsFailed != rhsFailed { return lhsFailed }
            return (lhs.startedAt ?? .distantPast) > (rhs.startedAt ?? .distantPast)
        }
    }

    /// Every run the monitor knows about, newest first.
    public var allRuns: [WorkflowRun] {
        state.runs.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    /// Worst status across live runs only.
    public var mood: IslandMood {
        if state.error != nil { return .error }
        var worst = IslandMood.idle
        for run in relevantRuns {
            let mood = Self.mood(for: run.status)
            if mood.rank > worst.rank { worst = mood }
        }
        return worst
    }

    static func mood(for status: RunStatus) -> IslandMood {
        if status.isActive { return .running }
        if status.isFailure { return .failed }
        switch status {
        case .success: return .success
        default: return .idle
        }
    }

    /// The run the collapsed pill describes — the worst one, newest first.
    public var headline: WorkflowRun? {
        let worst = mood
        return relevantRuns.first { Self.mood(for: $0.status) == worst } ?? relevantRuns.first
    }

    /// Everything the headline is *not* describing.
    public var otherRuns: [WorkflowRun] {
        guard let headline else { return [] }
        return relevantRuns.filter { $0.identity != headline.identity }
    }

    /// How many runs the collapsed island shows before it stops growing.
    private let collapsedRowLimit = 4

    /// The lines the collapsed island draws — one per live run.
    public var collapsedRuns: [WorkflowRun] {
        Array(relevantRuns.prefix(collapsedRowLimit))
    }

    /// Live runs that did not fit in the collapsed island.
    public var hiddenRunCount: Int {
        max(relevantRuns.count - collapsedRowLimit, 0)
    }

    /// Runs to draw job detail for when expanded.
    public var expandedDetail: [WorkflowRun] {
        Array(relevantRuns.prefix(6))
    }

    /// Distinct people behind the runs on screen.
    ///
    /// Only interesting when more than one person's work is visible, which is
    /// exactly when the pill needs to say whose run it is showing.
    public var visibleActors: [String] {
        var seen: [String] = []
        for run in relevantRuns {
            for login in run.logins.sorted() where !seen.contains(login) {
                seen.append(login)
            }
        }
        return seen
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
        guard !relevantRuns.contains(where: \.isActive) else { return 0 }
        guard let finished = relevantRuns.compactMap(\.finishedAt).max() else { return 0 }

        let age = now.timeIntervalSince(finished)
        let window = relevantRuns.contains { $0.status.isFailure } ? failedLinger : finishedLinger
        let dimStart = window * 0.66
        guard age > dimStart else { return 0 }
        return min((age - dimStart) / (window - dimStart), 1)
    }

    // MARK: - Ticker

    /// Only run a 1s timer when something is actually counting.
    private func updateTicker() {
        let needsTicker = !relevantRuns.isEmpty
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
                    self.recomputeRelevantRuns()
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
