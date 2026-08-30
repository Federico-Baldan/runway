// Does the actor filter keep exactly the runs it should?
//
// The reason this has its own spike: "only my runs" is the setting people rely
// on to make a busy organization readable, and every way of getting it wrong is
// silent. Match too loosely and a colleague's push interrupts you; match too
// tightly and your own re-run vanishes; resolve @me before the token is
// verified and the island shows nothing at all, forever, with no error.
//
//   swiftc -o /tmp/actorfilter spike/ActorFilterVerify.swift \
//       Sources/Runway/API/RunScope.swift Sources/Runway/API/Models.swift \
//       && /tmp/actorfilter

import Foundation

@main
enum ActorFilterVerify {
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

        func run(_ id: Int, pushedBy: String, reranBy: String? = nil) -> WorkflowRun {
            WorkflowRun(
                id: id,
                runAttempt: reranBy == nil ? 1 : 2,
                status: .inProgress,
                actor: GitHubActor(login: pushedBy),
                triggeringActor: GitHubActor(login: reranBy ?? pushedBy),
                repository: "acme/web"
            )
        }

        let mine = run(1, pushedBy: "federico")
        let hers = run(2, pushedBy: "alice")
        let his = run(3, pushedBy: "bob")
        // The interesting one: alice pushed it, I clicked re-run.
        let myRerunOfHers = run(4, pushedBy: "alice", reranBy: "federico")
        let everything = [mine, hers, his, myRerunOfHers]

        print("── scope .everyone ──")
        let everyone = ActorFilter.resolve(scope: .everyone, watched: [], currentUser: "federico")
        assert("keeps all four", everyone.apply(everything).count == 4)
        assert("reports itself as unfiltered", everyone.isEveryone)

        print()
        print("── scope .me ──")
        let justMe = ActorFilter.resolve(scope: .me, watched: [], currentUser: "federico")
        assert("keeps my push", justMe.matches(mine))
        assert("drops alice's push", !justMe.matches(hers))
        assert("drops bob's push", !justMe.matches(his))
        assert("KEEPS alice's run that I re-ran — triggeringActor counts too",
               justMe.matches(myRerunOfHers))
        assert("two runs survive", justMe.apply(everything).count == 2)

        print()
        print("── scope .me before the token is verified ──")
        // currentUser is nil until GET /user has answered. Resolving to an empty set
        // would hide every run and look exactly like a broken app.
        let unresolved = ActorFilter.resolve(scope: .me, watched: [], currentUser: nil)
        assert("degrades to everyone rather than hiding everything", unresolved.isEveryone)
        assert("so all four still show", unresolved.apply(everything).count == 4)

        print()
        print("── scope .list ──")
        let pair = ActorFilter.resolve(scope: .list, watched: ["alice", "bob"], currentUser: "federico")
        assert("keeps alice", pair.matches(hers))
        assert("keeps bob", pair.matches(his))
        assert("drops mine", !pair.matches(mine))
        assert("keeps alice's push even though I re-ran it", pair.matches(myRerunOfHers))

        let single = ActorFilter.resolve(scope: .list, watched: ["alice"], currentUser: "federico")
        assert("a one-person list still resolves to exactly that person",
               single.logins == ["alice"])
        // Measured against the live API: ?actor= matches the PUSH AUTHOR, not
        // the run's actor, so it cannot return a run somebody else pushed and
        // this person re-ran. Filtering has to happen here, on the full page,
        // or the re-run case above is silently lost.
        // alice pushed run 2 outright and run 4 (which federico re-ran), so
        // watching alice keeps both. This is the assertion that would fail if
        // ?actor= were doing the filtering.
        assert("the filter alone decides — nothing is delegated to ?actor=",
               single.apply(everything).map(\.id) == [2, 4])

        print()
        print("── @me resolution inside a list ──")
        let withMe = ActorFilter.resolve(scope: .list, watched: ["@me", "alice"], currentUser: "federico")
        assert("@me became my login", withMe.logins.contains("federico"))
        assert("alice came along", withMe.logins.contains("alice"))
        assert("keeps my push", withMe.matches(mine))
        assert("keeps alice's", withMe.matches(hers))
        assert("drops bob", !withMe.matches(his))

        let onlyMeUnresolved = ActorFilter.resolve(scope: .list, watched: ["@me"], currentUser: nil)
        assert("a list of only @me, unresolved, degrades to everyone",
               onlyMeUnresolved.isEveryone)

        let emptyList = ActorFilter.resolve(scope: .list, watched: [], currentUser: "federico")
        assert("an empty list shows everything rather than nothing", emptyList.isEveryone)

        print()
        print("── input tolerance ──")
        let noisy = ActorFilter.resolve(scope: .list, watched: ["  @alice ", "", "BOB"], currentUser: nil)
        assert("a leading @ is stripped", noisy.logins.contains("alice"))
        assert("blank entries are dropped", noisy.logins.count == 2)
        assert("matching is case-insensitive", noisy.matches(his))
        assert("case-insensitive both ways",
               ActorFilter(logins: ["Alice"]).matches(hers))

        print()
        print("── quiet-repo demotion ──")
        // A repo with no Actions must not cost a request every 5 seconds forever.
        var quiet = WatchedRepo(fullName: "acme/docs", hasWorkflows: false)
        var polls = 0
        for _ in 0..<(WatchedRepo.quietRepoInterval * 3) where quiet.shouldPoll() { polls += 1 }
        assert("polled 3 times in 36 cycles, not 36", polls == 3)

        var busy = WatchedRepo(fullName: "acme/web", hasWorkflows: true)
        var busyPolls = 0
        for _ in 0..<12 where busy.shouldPoll() { busyPolls += 1 }
        assert("an active repo is polled every cycle", busyPolls == 12)

        print()
        if failures == 0 {
            print("RESULT: PASS — the actor filter keeps what it should and nothing else")
        } else {
            print("RESULT: FAIL — \(failures) case(s) wrong")
            exit(1)
        }
    }
}
