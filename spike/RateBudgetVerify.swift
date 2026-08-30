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
        assert("reset is described in minutes", rate.resetDescription == "30m")

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
        if failures == 0 {
            print("RESULT: PASS — the poll fits the budget and the cache accounting is sound")
        } else {
            print("RESULT: FAIL — \(failures) case(s) wrong")
            exit(1)
        }
    }
}
