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
        let body: Data
        var refreshedAt: Date
    }

    private var entries: [String: Entry] = [:]

    /// Entries older than this are dropped, so a repository that stops being
    /// watched does not pin its body in memory forever.
    private let maxAge: TimeInterval = 3_600

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

    /// The body cached alongside that ETag — what a 304 resolves to.
    func body(for key: String) -> Data? {
        entries[key]?.body
    }

    /// Remember a 200 response.
    mutating func store(key: String, etag: String?, body: Data) {
        guard let etag, !etag.isEmpty else {
            // No validator offered: drop any stale entry rather than pairing a
            // fresh body with an old ETag.
            entries[key] = nil
            return
        }
        entries[key] = Entry(etag: etag, body: body, refreshedAt: Date())
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
