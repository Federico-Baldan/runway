import Foundation

/// Conditional-request cache: one ETag and one cached body per URL.
///
/// This is the single most important piece of rate-limit engineering in the
/// app, and it exists because of one documented GitHub behaviour:
///
/// > A conditional request does not count against your primary rate limit if a
/// > 304 is returned and the request was correctly authorized.
///
/// Runway polls up to 20 repositories every 5 seconds while something is
/// building. Unconditionally that is 14,400 requests an hour against a 5,000
/// budget — it would be rate-limited within twenty minutes. Conditionally,
/// almost every one of those comes back `304 Not Modified` and costs nothing,
/// because a repository that is not building does not change.
///
/// Two caveats, both load-bearing:
///
///  * The exemption requires the `Authorization` header. An **unauthenticated**
///    304 still decrements the limit, so an empty token must never fall through
///    to a real request — `GitHubClient.get` throws `.noToken` first.
///  * ETags are scoped per token. `invalidate()` therefore runs on every token
///    change, or the first poll after a switch would serve another account's
///    cached bodies.
struct ETagStore: Sendable {
    struct Entry: Sendable {
        let etag: String
        /// The raw response body, kept only until it has been decoded once —
        /// see `memoise(_:for:)`.
        var body: Data
        var refreshedAt: Date
        /// What `body` decoded to, so a 304 costs no JSON parsing.
        ///
        /// A 304 is GitHub saying "the bytes have not changed", and the whole
        /// reason this store exists is that the answer is then already known.
        /// It was still being paid for in full: every 304 re-ran
        /// `JSONDecoder` over the cached body to rebuild a value identical to
        /// the last one. On twenty repositories at the five-second active
        /// cadence that is twenty run-list payloads parsed a second, each one
        /// thirty runs deep with an ISO-8601 date on every timestamp — by some
        /// distance the largest recurring CPU cost in an app whose entire
        /// point is to be cheap while nothing is happening.
        var decoded: (any Sendable)?
    }

    private var entries: [String: Entry] = [:]

    /// Entries older than this are dropped, so a repository that stops being
    /// watched does not pin its body in memory forever.
    private let maxAge: TimeInterval = 3_600

    /// How many entries the store will hold, whatever their age.
    ///
    /// Age alone was not a bound. Every entry keeps a **full response body**,
    /// and while the `runs:` and `orgrepos:` keys are one per repository — a
    /// bounded set — the `jobs:`, `pending:` and `approvals:` keys carry a run
    /// id, so the store mints three new entries for every run that has ever
    /// been interesting and holds each for an hour after it was last touched.
    /// A busy account can start hundreds of runs in an hour, and a run list at
    /// `per_page=30` is not a small body: the hour-long window was the only
    /// thing standing between this and tens of megabytes of JSON resident in a
    /// menu bar app.
    ///
    /// 300 is comfortably more than the working set the poll actually
    /// revalidates — 100 repositories is the configured ceiling, and only runs
    /// the island is drawing get job detail — so the cap is reached by *dead*
    /// entries first, which is exactly what should be evicted.
    private let maxEntries = 300

    /// When the last sweep ran, so the store is not re-filtered on every
    /// request — the poll can fire every five seconds.
    private var lastPrune = Date()
    /// How often the sweep is worth running: well under `maxAge`, so nothing
    /// outlives its window by much, and far above the poll cadence.
    private let pruneInterval: TimeInterval = 120

    init() {}

    /// The ETag to send as `If-None-Match`, if one is held.
    ///
    /// Mutating, because reading the validator *is* using the entry. A 304
    /// resolves against the body cached beside it, and the sweep runs on the
    /// request path — so an entry read at the very edge of `maxAge` could be
    /// evicted by another repository's request during the round trip, leaving
    /// the 304 with nothing to resolve to. `GitHubClient` turns that into a
    /// `.network` error, which is retryable, which means one evicted body
    /// failed the whole poll and put every other repository behind a backoff
    /// curve. Marking the entry fresh here closes the window outright.
    mutating func etag(for key: String) -> String? {
        guard let etag = entries[key]?.etag else { return nil }
        entries[key]?.refreshedAt = Date()
        return etag
    }

    /// The body cached alongside that ETag — what a 304 resolves to when no
    /// decode has been memoised for it yet.
    ///
    /// Empty reads as absent, because that is what `memoise(_:for:)` leaves
    /// behind when it releases the bytes: an entry that has already been
    /// decoded has nothing here worth handing back, and the caller's own
    /// "cache miss on a 304" path is the right answer if the memo somehow
    /// cannot serve it. No real response this store keeps is zero bytes — the
    /// empty JSON array is `[]`.
    func body(for key: String) -> Data? {
        guard let body = entries[key]?.body, !body.isEmpty else { return nil }
        return body
    }

    /// The value this entry's body decoded to, if it is still the type being
    /// asked for.
    ///
    /// Typed rather than blind: one cache key only ever names one endpoint, so
    /// the cast cannot fail in practice — but if it ever did, answering `nil`
    /// sends the caller down the unconditional-refetch path it already has
    /// rather than handing back somebody else's payload.
    func decoded<Value: Sendable>(for key: String) -> Value? {
        guard let stored = entries[key]?.decoded else { return nil }
        return stored as? Value
    }

    /// Remember what an entry's body decoded to, and release the bytes.
    ///
    /// The body has exactly one reader — the decode a 304 would otherwise
    /// perform — so once its answer is here the JSON is dead weight. And it is
    /// the *large* half by a margin worth measuring rather than guessing at.
    ///
    /// Measured against live GitHub, `per_page=30` with `exclude_pull_requests`
    /// already on: 385 KB for grafana/grafana, 365 KB for Homebrew/brew. Of
    /// that, the fields `WorkflowRun` actually decodes come to **4.4–4.8%** —
    /// every run carries a full `repository` object, a `head_repository`, a
    /// `head_commit`, and a wall of `*_url` links, and this app reads none of
    /// them. So roughly 366 KB per cached repository was being held to answer a
    /// question worth 18 KB, and `spike/SchemaVerify.swift` re-measures it.
    ///
    /// At the hundred-repository ceiling that is the difference between tens of
    /// megabytes of JSON resident in a menu bar app and a couple of megabytes
    /// of decoded runs — which is the outcome `maxAge` and `maxEntries` were
    /// reaching for and could only bound, never remove.
    mutating func memoise<Value: Sendable>(_ value: Value, for key: String) {
        guard entries[key] != nil else { return }
        entries[key]?.decoded = value
        entries[key]?.body = Data()
    }

    /// Remember a 200 response.
    mutating func store(key: String, etag: String?, body: Data) {
        guard let etag, !etag.isEmpty else {
            // No validator offered: drop any stale entry rather than pairing a
            // fresh body with an old ETag.
            entries[key] = nil
            return
        }
        // `decoded: nil` spelled out rather than left to the memberwise
        // default: a fresh body invalidates the previous decode, and this is
        // the one place that could pair the two by omission.
        entries[key] = Entry(etag: etag, body: body, refreshedAt: Date(), decoded: nil)
        evictOverflow()
    }

    /// Drop the least recently revalidated entries until the store is back
    /// under `maxEntries`.
    ///
    /// Least-recently-refreshed rather than oldest-written: `etag(for:)` and
    /// `touch(key:)` both restamp, so an entry the poll keeps revalidating —
    /// a watched repository's run list — stays no matter how long ago its body
    /// arrived, and the ones evicted are the runs nothing has asked about since.
    ///
    /// Only ever reached on a write, and only when the store is over the line,
    /// so the sort costs nothing on a normal poll.
    private mutating func evictOverflow() {
        guard entries.count > maxEntries else { return }
        let doomed = entries
            .sorted { $0.value.refreshedAt < $1.value.refreshedAt }
            .prefix(entries.count - maxEntries)
        for entry in doomed { entries[entry.key] = nil }
    }

    /// Mark an entry as still current after a 304.
    mutating func touch(key: String) {
        entries[key]?.refreshedAt = Date()
    }

    /// Drop everything. Runs on token change — ETags are per-token.
    mutating func invalidate() {
        entries.removeAll()
    }

    /// Evict entries nothing has revalidated for an hour.
    mutating func prune(now: Date = Date()) {
        lastPrune = now
        entries = entries.filter { now.timeIntervalSince($0.value.refreshedAt) < maxAge }
    }

    /// Run `prune` if it is due, cheaply enough to sit on the request path.
    ///
    /// The sweep has to be driven by something. It is not on a timer, because a
    /// suspended app makes no requests and so grows nothing; the only moment
    /// the store can gain an entry is a request, which makes the request the
    /// right place to check.
    mutating func pruneIfDue(now: Date = Date()) {
        guard now.timeIntervalSince(lastPrune) >= pruneInterval else { return }
        prune(now: now)
    }

    /// How many URLs are cached. Surfaced by `--diagnose`.
    var count: Int { entries.count }
}

/// What the primary rate limit looked like on the last response.
public struct RateLimit: Sendable, Equatable {
    public var limit: Int
    public var remaining: Int
    public var resetsAt: Date?
    /// Requests that actually cost budget since the app started — 304s excluded.
    public var billedRequests: Int
    /// Requests answered from the conditional cache, costing nothing.
    public var savedRequests: Int

    public init(
        limit: Int = 0,
        remaining: Int = 0,
        resetsAt: Date? = nil,
        billedRequests: Int = 0,
        savedRequests: Int = 0
    ) {
        self.limit = limit
        self.remaining = remaining
        self.resetsAt = resetsAt
        self.billedRequests = billedRequests
        self.savedRequests = savedRequests
    }

    /// Fraction of the hourly budget still available, 0...1.
    public var headroom: Double {
        guard limit > 0 else { return 1 }
        return max(min(Double(remaining) / Double(limit), 1), 0)
    }

    /// Close enough to the ceiling that the monitor should slow down.
    public var isTight: Bool { limit > 0 && headroom < 0.15 }

    /// Share of polls served by a 304.
    public var cacheHitRate: Double {
        let total = billedRequests + savedRequests
        guard total > 0 else { return 0 }
        return Double(savedRequests) / Double(total)
    }

    public var resetDescription: String {
        guard let resetsAt else { return "unknown" }
        let seconds = Int(resetsAt.timeIntervalSinceNow)
        guard seconds > 0 else { return "now" }
        return seconds >= 60 ? "\(seconds / 60)m" : "\(seconds)s"
    }
}
