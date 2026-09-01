// What happens to a poll that is still in the air when the scope changes?
//
// The bug this exists for: `pollOnce` walked `for index in watched.indices`
// and wrote `watched[index].hasWorkflows` after `await client.fetchRuns(...)`.
// An actor is re-entrant, so that await is a point where `configure(_:)` gets
// to run — and picking a different repository scope in Settings makes it set
// `watched = []`. The range had already been materialised, so the resumption
// indexed an emptied array: `Fatal error: Index out of range`, intermittently,
// on exactly the click that caused it.
//
// The loop now works off a snapshot and folds the result back BY NAME. That
// merge is the half with an answer worth asserting, and it needs no actor and
// no network to assert it. Also checked here: the `affiliation` strings the
// repository scopes resolve to, because "repositories I contribute to" is one
// missing word away from silently meaning "all of them".
//
//   swiftc -o /tmp/reentrancy spike/ReentrancyVerify.swift \
//       Sources/Runway/Core/RunMonitor.swift Sources/Runway/API/GitHubClient.swift \
//       Sources/Runway/API/Models.swift Sources/Runway/API/Approvals.swift \
//       Sources/Runway/API/RunScope.swift Sources/Runway/API/ETagStore.swift \
//       Sources/Runway/Auth/Keychain.swift \
//       && /tmp/reentrancy

import Foundation

@main
enum ReentrancyVerify {
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

        func repo(_ name: String, hasWorkflows: Bool = true, skipped: Int = 0) -> WatchedRepo {
            WatchedRepo(fullName: name, hasWorkflows: hasWorkflows, skippedCycles: skipped)
        }

        func flags(_ list: [WatchedRepo]) -> [String: Bool] {
            Dictionary(list.map { ($0.fullName, $0.hasWorkflows) }, uniquingKeysWith: { a, _ in a })
        }

        print("── the merge lands each verdict on the repository it came from ──")
        // The poll learned that b has no Actions. The live list has since been
        // re-ordered, so a positional write-back would demote `a` instead.
        let polled = [
            repo("acme/a", hasWorkflows: true),
            repo("acme/b", hasWorkflows: false),
            repo("acme/c", hasWorkflows: true),
        ]
        let reordered = [repo("acme/c"), repo("acme/b"), repo("acme/a")]
        let merged = RunMonitor.merged(reordered, polled: polled)
        assert("order is the LIVE list's, not the poll's",
               merged.map(\.fullName) == ["acme/c", "acme/b", "acme/a"])
        assert("acme/b is the one demoted", flags(merged)["acme/b"] == false)
        assert("acme/a keeps its workflows", flags(merged)["acme/a"] == true)
        assert("acme/c keeps its workflows", flags(merged)["acme/c"] == true)

        print()
        print("── a shorter live list is a merge, not a crash ──")
        // This is the shape the bug produced: the poll walked twenty
        // repositories, `configure` emptied the list underneath it, and the
        // write-back had nowhere to land. It must land nowhere, quietly.
        assert("emptied list survives twenty results",
               RunMonitor.merged([], polled: polled).isEmpty)
        let narrowed = RunMonitor.merged([repo("acme/b")], polled: polled)
        assert("one survivor keeps only its own verdict",
               narrowed.count == 1 && narrowed[0].hasWorkflows == false)

        print()
        print("── a repository the poll never saw is left alone ──")
        // The five-minute rediscovery can add a repository mid-poll. It has no
        // verdict yet, and inventing one would demote a repo nothing checked.
        let widened = RunMonitor.merged(
            [repo("acme/b"), repo("acme/brand-new")],
            polled: polled
        )
        assert("the new repository is untouched",
               widened.last?.fullName == "acme/brand-new" && widened.last?.hasWorkflows == true)
        assert("an empty poll changes nothing",
               RunMonitor.merged(reordered, polled: []).map(\.fullName)
                   == reordered.map(\.fullName))

        print()
        print("── the demotion counter survives the round trip ──")
        // `shouldPoll()` is mutating and now runs on the snapshot, so its
        // bookkeeping has to come back or a quiet repo is polled every cycle
        // forever — the exact waste WatchedRepo exists to avoid.
        var quiet = repo("acme/quiet", hasWorkflows: false, skipped: 0)
        var polls = 0
        for _ in 0..<WatchedRepo.quietRepoInterval {
            if quiet.shouldPoll() { polls += 1 }
        }
        assert("a quiet repo is polled once per \(WatchedRepo.quietRepoInterval) cycles", polls == 1)

        // Three more cycles, so the counter is mid-window and has something to
        // lose. A merge that dropped it would restart the wait every poll.
        var partial = repo("acme/quiet", hasWorkflows: false, skipped: 0)
        for _ in 0..<3 { _ = partial.shouldPoll() }
        assert("three skipped cycles are counted", partial.skippedCycles == 3)
        let carried = RunMonitor.merged([repo("acme/quiet")], polled: [partial])
        assert("the skip count comes back with the merge", carried.first?.skippedCycles == 3)
        assert("so does the no-workflows verdict", carried.first?.hasWorkflows == false)

        print()
        print("── which repositories each scope actually asks GitHub for ──")
        // `affiliation` is a union, so leaving `owner` out of it is what makes
        // "repositories I contribute to" exclude your own — including the
        // private ones a client-side owner check would never have fetched.
        let contributor = RepoScope.contributor.affiliation ?? ""
        assert("contributor asks for collaborator repositories",
               contributor.contains("collaborator"))
        assert("contributor asks for organization repositories",
               contributor.contains("organization_member"))
        assert("contributor does NOT ask for owned repositories",
               !contributor.split(separator: ",").map(String.init).contains("owner"))
        assert("mine asks for owned repositories only",
               RepoScope.mine.affiliation == "owner")
        assert("recent asks for all three",
               RepoScope.recent.affiliation == "owner,collaborator,organization_member")
        // These two resolve through other endpoints entirely; sending an
        // affiliation for them would be meaningless, and GitHub answers 422 to
        // `type` and `affiliation` together, so neither may grow a `type`.
        assert("organizations resolves elsewhere", RepoScope.organizations.affiliation == nil)
        assert("explicit resolves elsewhere", RepoScope.explicit.affiliation == nil)
        assert("every scope is covered", RepoScope.allCases.count == 5)

        print()
        if failures == 0 {
            print("RESULT: PASS — the merge is name-keyed and every scope asks for what it says")
        } else {
            print("RESULT: FAIL — \(failures) case(s) wrong")
            exit(1)
        }
    }
}
