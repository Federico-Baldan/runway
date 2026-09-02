import Foundation

/// Runs the user has taken off the island by hand, remembered across launches.
///
/// The island decides what to show from rules — is it moving, did it break, is
/// somebody waiting on you — and those rules are right almost all of the time.
/// This is the escape hatch for the rest: a run you have already dealt with,
/// a red one you are not going to fix today, a deploy you rejected on purpose
/// and do not need reminding about for the next ten minutes.
///
/// **Local, and only local.** Nothing is sent to GitHub and nothing is deleted
/// there; the run is exactly where it was, and `restore()` brings every
/// dismissal back. That is deliberate rather than a limitation: Runway's token
/// is read-only by design — the same reason it shows you an approval and sends
/// you to GitHub to grant it — and "get this off my screen" does not need write
/// access to anybody's repository.
///
/// Free functions over `UserDefaults` rather than an object: an `@Observable`
/// wrapper would have bought a hop in each direction and nothing else.
///
/// The four that touch `UserDefaults` are `@MainActor`, the two that are pure
/// arithmetic are not. Under Swift 6's strict concurrency the store is reached
/// from two isolation domains — Settings reads it on the main actor, the
/// `RunMonitor` actor writes it — and pinning every write to the main actor is
/// one hop for something that happens on a click, in exchange for never having
/// to be right about whether `UserDefaults` is `Sendable` on the SDK of the
/// day. `prune` stays free of all of it so the spike can check the retention
/// rule without a main actor to run on.
public enum DismissedRuns {
    private static let key = "island.dismissedRuns"

    /// How long a dismissal is remembered.
    ///
    /// A run leaves the island within ten minutes and drops out of the thirty
    /// most recent runs long before this, so the entry is dead weight well
    /// ahead of expiring — but the identity carries a run id, so the dictionary
    /// mints a new key every time and would otherwise grow for the life of the
    /// installation. Two weeks is long enough that nobody will see a dismissal
    /// come undone and short enough that the list stays small.
    static let retention: TimeInterval = 14 * 24 * 60 * 60

    /// Everything still dismissed, with anything expired dropped on the way out.
    ///
    /// Pruning on read rather than on a timer: this is called at launch and the
    /// answer is written straight back, so the store is compacted exactly when
    /// somebody is looking at it and never in the background.
    @MainActor
    public static func load(
        from defaults: UserDefaults = .standard,
        now: Date = Date()
    ) -> Set<String> {
        let stored = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        let live = prune(stored, now: now)
        if live.count != stored.count { defaults.set(live, forKey: key) }
        return Set(live.keys)
    }

    /// Write the set back, stamping anything newly dismissed with the time.
    ///
    /// Existing stamps are carried over rather than refreshed, so a dismissal
    /// expires two weeks after the click and not two weeks after the last time
    /// the app happened to save.
    @MainActor
    public static func save(
        _ identities: Set<String>,
        to defaults: UserDefaults = .standard,
        now: Date = Date()
    ) {
        let previous = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        let stamp = now.timeIntervalSinceReferenceDate
        var next: [String: Double] = [:]
        for identity in identities {
            next[identity] = previous[identity] ?? stamp
        }
        defaults.set(next, forKey: key)
    }

    /// How many runs are currently hidden, for the line in Settings that
    /// offers to bring them back.
    @MainActor
    public static func count(
        in defaults: UserDefaults = .standard,
        now: Date = Date()
    ) -> Int {
        let stored = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        return prune(stored, now: now).count
    }

    /// Forget every dismissal.
    @MainActor
    public static func restore(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    /// The retention rule as a pure function, so it can be checked without a
    /// `UserDefaults` or a clock — `spike/DismissVerify.swift` pins it.
    static func prune(_ stored: [String: Double], now: Date) -> [String: Double] {
        let cutoff = now.timeIntervalSinceReferenceDate - retention
        return stored.filter { $0.value > cutoff }
    }
}
