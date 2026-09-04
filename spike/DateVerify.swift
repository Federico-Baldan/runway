// Can one odd timestamp take the whole app dark?
//
// The date strategy in `GitHubClient`'s decoder has no way to say "skip this
// field": `GitHubDate.parse` returning nil becomes a thrown `.decoding`, which
// fails the decode, fails the poll, and puts "Could not read GitHub's response"
// on the island for as long as the shape keeps arriving. So the question is not
// which timestamps are pretty — it is which ones are survivable.
//
// `withFractionalSeconds` accepts three, six or nine digits, which is Apple's
// documented set and nothing more. Four digits, or one, and it returns nil.
// GitHub sends whole seconds for Actions timestamps today, so this is a fuse
// rather than a fire — but it is a fuse on the entire app, over sub-second
// precision that every window here discards anyway.
//
//   swiftc -o /tmp/dateverify spike/DateVerify.swift \
//       Sources/Runway/API/GitHubClient.swift Sources/Runway/API/Models.swift \
//       Sources/Runway/API/Approvals.swift Sources/Runway/API/DeployTarget.swift \
//       Sources/Runway/API/RunScope.swift Sources/Runway/API/ETagStore.swift \
//       Sources/Runway/Auth/Keychain.swift && /tmp/dateverify
import Foundation
@main enum DateVerify {
    static func main() {
        var f = 0
        func a(_ l: String, _ c: Bool) { if c { print("  ok    \(l)") } else { print("  FAIL  \(l)"); f += 1 } }
        func p(_ s: String) -> Date? { GitHubDate.parse(s) }
        let ref = p("2026-01-01T12:34:56Z")

        print("── the shapes GitHub actually sends ──")
        a("whole seconds, Z", ref != nil)
        a("milliseconds (3 digits)", p("2026-01-01T12:34:56.123Z") != nil)
        a("microseconds (6)", p("2026-01-01T12:34:56.123456Z") != nil)
        a("nanoseconds (9)", p("2026-01-01T12:34:56.123456789Z") != nil)
        a("numeric offset", p("2026-01-01T12:34:56+01:00") != nil)

        print()
        print("── digit counts withFractionalSeconds does NOT accept ──")
        for n in [1, 2, 4, 5, 7, 8, 10, 12] {
            let frac = String(repeating: "7", count: n)
            a("\(n) fractional digit\(n == 1 ? "" : "s") still reads",
              p("2026-01-01T12:34:56.\(frac)Z") != nil)
        }
        // Correct TO THE SECOND, not identical: a lenient platform may parse
        // the fraction outright and keep it, while a strict one falls through
        // to the truncating path and does not. Both are right for an app whose
        // every window is measured in whole seconds.
        func sameSecond(_ a: Date?, _ b: Date?) -> Bool {
            guard let a, let b else { return false }
            return abs(a.timeIntervalSince(b)) < 1
        }
        a("the offset survives the fraction being dropped",
          sameSecond(p("2026-01-01T12:34:56.7777+01:00"), p("2026-01-01T12:34:56+01:00")))
        a("and an odd fraction still lands on the right second",
          sameSecond(p("2026-01-01T12:34:56.7777Z"), ref))
        a("a +01:00 offset is still an hour off UTC, so the fallback did not eat it",
          abs((p("2026-01-01T12:34:56.7777+01:00")?.timeIntervalSince(ref!) ?? 0) + 3600) < 1)

        print()
        print("── and still refuses what is not a date ──")
        for bad in ["", ".", "..Z", "2026-01-01", "not-a-date", "2026-01-01T12:34:56.", "....Z", "🙂.1Z"] {
            a("rejects \"\(bad)\"", p(bad) == nil)
        }

        print()
        print(f == 0 ? "RESULT: PASS — an unexpected fraction no longer takes the poll down"
                     : "RESULT: FAIL — \(f)")
        exit(f == 0 ? 0 : 1)
    }
}
