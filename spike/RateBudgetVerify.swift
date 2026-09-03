// Does the polling budget actually fit inside GitHub's 5,000 requests an hour?
//
// This is arithmetic, not a unit test, and it exists because getting it wrong is
// invisible until the island dies at 20 past the hour. Conditional requests are
// the whole reason the design is affordable: a 304 costs nothing against the
// primary limit, so a repository that is not building is free to watch.
//
//   swiftc -o /tmp/ratebudget spike/RateBudgetVerify.swift \
//       Sources/Runway/API/ETagStore.swift Sources/Runway/API/RunScope.swift \
//       Sources/Runway/API/Models.swift && /tmp/ratebudget

import Foundation

@main
enum RateBudgetVerify {
    static func main() {
        var failures = 0

        func assert(_ label: String, _ condition: Bool) {
            if condition {
                print("  ok    \(label)")
            } else {
                print("  FAIL  \(label)")
                failures += 1
            }
        }

        let hourlyBudget = 5_000.0

        print("── worst case: every request unconditional ──")
        let repos = 20.0
        let activeCadence = 5.0
        let ticksPerHour = 3_600.0 / activeCadence
        let naive = repos * ticksPerHour
        print("  \(Int(repos)) repos x \(Int(ticksPerHour)) ticks = \(Int(naive)) requests/hour")
        assert("an unconditional poll WOULD blow the budget (this is the problem)",
               naive > hourlyBudget)
        print("  -> would be rate-limited after ~\(Int(hourlyBudget / repos * activeCadence / 60)) minutes")

        print()
        print("── real case: only changed repositories cost anything ──")
        // While one repo is building, that repo's runs list changes every tick. The
        // other nineteen return 304 and are free.
        let building = 1.0
        let billedPerTick = building * 2      // its runs list, plus its jobs
        let billed = billedPerTick * ticksPerHour
        print("  1 repo building, 19 unchanged -> \(Int(billedPerTick)) billed/tick = \(Int(billed))/hour")
        assert("fits inside the budget with room to spare", billed < hourlyBudget * 0.5)

        print()
        print("── idle: nothing building at all ──")
        let idleTicks = 3_600.0 / 15.0
        print("  idle cadence 15s -> \(Int(idleTicks)) ticks, all 304 -> ~0 billed")
        assert("idle polling is effectively free", idleTicks * 0 < hourlyBudget)

        print()
        print("── the exemption only applies when authenticated ──")
        // An unauthenticated 304 still decrements the limit. GitHubClient throws
        // .noToken before building a request, so this can never happen — but the
        // arithmetic is why that guard is load-bearing rather than tidy.
        let unauthenticated = repos * ticksPerHour
        assert("without a token the naive number applies again", unauthenticated > hourlyBudget)

        print()
        print("── RateLimit accounting ──")
        var rate = RateLimit(limit: 5000, remaining: 4200, resetsAt: Date().addingTimeInterval(1800),
                             billedRequests: 300, savedRequests: 2700)
        assert("headroom is remaining/limit", abs(rate.headroom - 0.84) < 0.001)
        assert("84% headroom is not tight", !rate.isTight)
        assert("cache hit rate is saved/(saved+billed)", abs(rate.cacheHitRate - 0.9) < 0.001)
        // resetDescription reads the clock, so 1800s has already become 1799 by
        // the time it is formatted. Assert the format and the magnitude, not an
        // exact string — an exact one is a test that fails for being correct.
        let described = rate.resetDescription
        assert("reset is described in whole minutes (got \(described))",
               described.hasSuffix("m") && (Int(described.dropLast()) ?? 0) >= 29)

        let soon = RateLimit(limit: 5000, remaining: 10, resetsAt: Date().addingTimeInterval(45))
        assert("under a minute is described in seconds (got \(soon.resetDescription))",
               soon.resetDescription.hasSuffix("s"))
        let past = RateLimit(limit: 5000, remaining: 10, resetsAt: Date().addingTimeInterval(-5))
        assert("an elapsed reset reads as now, not a negative", past.resetDescription == "now")
        assert("no reset header at all is reported honestly",
               RateLimit().resetDescription == "unknown")

        rate.remaining = 400
        assert("8% headroom IS tight, so the monitor should conserve", rate.isTight)

        let unknown = RateLimit()
        assert("with no headers yet, assume full headroom rather than throttling",
               unknown.headroom == 1.0 && !unknown.isTight)
        assert("and report no cache rate rather than dividing by zero",
               unknown.cacheHitRate == 0)

        print()
        print("── ETagStore ──")
        var store = ETagStore()
        let body = Data("[]".utf8)
        store.store(key: "runs:acme/web", etag: "W/\"abc\"", body: body)
        assert("an ETag is handed back for If-None-Match", store.etag(for: "runs:acme/web") == "W/\"abc\"")
        assert("and the body is there to resolve a 304 against", store.body(for: "runs:acme/web") == body)

        // A 200 with no ETag must not leave a stale validator paired with a fresh body.
        store.store(key: "runs:acme/web", etag: nil, body: Data("[1]".utf8))
        assert("a response without an ETag drops the entry entirely",
               store.etag(for: "runs:acme/web") == nil && store.body(for: "runs:acme/web") == nil)

        store.store(key: "a", etag: "1", body: body)
        store.store(key: "b", etag: "2", body: body)
        assert("two entries cached", store.count == 2)
        store.invalidate()
        assert("a token change clears everything — ETags are per-token", store.count == 0)

        print()
        print("── the decode memo ──")
        // A 304 says the bytes are unchanged, which means the value they parse
        // to is unchanged as well. Re-running JSONDecoder over the cached body
        // to rebuild it was the single largest recurring CPU cost in the app:
        // twenty run lists, thirty runs deep, every five seconds, for an answer
        // already known. See ETagStore.Entry.decoded.
        var memo = ETagStore()
        memo.store(key: "runs:acme/web", etag: "W/\"abc\"", body: Data("[1,2,3]".utf8))
        let parsed = [1, 2, 3]
        memo.memoise(parsed, for: "runs:acme/web")
        let recalled: [Int]? = memo.decoded(for: "runs:acme/web")
        assert("a 304 resolves against the memo rather than re-parsing", recalled == parsed)
        assert("and the raw JSON is released once it has been decoded — it has "
               + "no other reader, and it is the larger half",
               memo.body(for: "runs:acme/web") == nil)
        assert("the ETag survives, so the request stays conditional",
               memo.etag(for: "runs:acme/web") == "W/\"abc\"")

        // A wrong-typed recall must decline rather than hand back somebody
        // else's payload. One cache key only ever names one endpoint, so this
        // cannot happen in the app — but "cannot" is what assertions are for.
        let mistyped: [String]? = memo.decoded(for: "runs:acme/web")
        assert("a memo of the wrong type is declined, not force-cast", mistyped == nil)

        // A fresh 200 body invalidates the previous decode. Pairing new bytes
        // with an old memo would freeze the island on last week's runs.
        memo.store(key: "runs:acme/web", etag: "W/\"def\"", body: Data("[4]".utf8))
        let afterRestore: [Int]? = memo.decoded(for: "runs:acme/web")
        assert("a new body clears the memo it invalidates", afterRestore == nil)
        assert("and the new bytes are there to decode", memo.body(for: "runs:acme/web") != nil)

        print()
        if failures == 0 {
            print("RESULT: PASS — the poll fits the budget and the cache accounting is sound")
        } else {
            print("RESULT: FAIL — \(failures) case(s) wrong")
            exit(1)
        }
    }
}
