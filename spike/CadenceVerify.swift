// What does the poll loop actually do when two power signals disagree?
//
// The cadence has five inputs — retry backoff, screen sleep, Low Power Mode,
// rate-limit headroom, and whether anything is building — and they are checked
// in an order that decides the answer. That ordering is exactly the kind of
// thing that reads as obviously correct and is not: a `return` in the wrong
// branch silently drops a slower constraint on the floor, and the symptom is a
// battery complaint weeks later, on somebody else's laptop.
//
//   swiftc -o /tmp/cadence spike/CadenceVerify.swift \
//       Sources/Runway/Core/RunMonitor.swift Sources/Runway/API/GitHubClient.swift \
//       Sources/Runway/API/Models.swift Sources/Runway/API/RunScope.swift \
//       Sources/Runway/API/ETagStore.swift Sources/Runway/Auth/Keychain.swift \
//       && /tmp/cadence

import Foundation

@main
enum CadenceVerify {
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

        let cadence = RunMonitor.Cadence()

        func interval(
            failures failureCount: Int = 0,
            suspended: Bool = false,
            lowPower: Bool = false,
            tight: Bool = false,
            active: Bool = false
        ) -> TimeInterval {
            RunMonitor.interval(
                cadence: cadence,
                failureCount: failureCount,
                isSuspended: suspended,
                isLowPower: lowPower,
                isRateLimitTight: tight,
                hasActiveRun: active
            )
        }

        print("── the ordinary cases ──")
        assert("idle polls at \(Int(cadence.idle))s", interval() == cadence.idle)
        assert("a live run polls at \(Int(cadence.active))s", interval(active: true) == cadence.active)

        print()
        print("── backoff outranks everything ──")
        // A failing request retried faster helps nobody, and the reason it is
        // failing may be the very thing the other signals are about.
        assert("one failure -> backoffBase", interval(failures: 1) == cadence.backoffBase)
        assert("four failures -> 40s", interval(failures: 4) == 40)
        assert("backoff is capped", interval(failures: 20) == cadence.backoffCeiling)
        assert(
            "backoff wins over a live run",
            interval(failures: 3, active: true) == cadence.backoffBase * 4
        )

        print()
        print("── a dark screen outranks the rest ──")
        assert("suspended -> \(Int(cadence.suspended))s", interval(suspended: true) == cadence.suspended)
        assert(
            "suspended wins over a live run",
            interval(suspended: true, active: true) == cadence.suspended
        )
        assert(
            "suspended wins over Low Power Mode",
            interval(suspended: true, lowPower: true) == cadence.suspended
        )

        print()
        print("── floors, not replacements ──")
        // This is the regression the whole spike exists for. Both Low Power Mode
        // and a nearly-spent rate-limit budget slow the loop down. If either is
        // written as `return` rather than as a floor, whichever is checked first
        // wins and the other is silently discarded — including when it was the
        // slower, and therefore the binding, one.
        assert(
            "Low Power Mode raises an idle poll to \(Int(cadence.lowPower))s",
            interval(lowPower: true) == cadence.lowPower
        )
        assert(
            "Low Power Mode raises an ACTIVE poll to \(Int(cadence.lowPower))s too",
            interval(lowPower: true, active: true) == cadence.lowPower
        )
        assert(
            "a tight budget raises an active poll to \(Int(cadence.conserving))s",
            interval(tight: true, active: true) == cadence.conserving
        )
        assert(
            "with both, the SLOWER one wins",
            interval(lowPower: true, tight: true, active: true)
                == max(cadence.conserving, cadence.lowPower)
        )

        print()
        print("── the floors never speed anything up ──")
        // A floor that could lower the interval would turn a battery-saving
        // signal into a battery-spending one.
        for lowPower in [false, true] {
            for tight in [false, true] {
                for active in [false, true] {
                    let base = active ? cadence.active : cadence.idle
                    let got = interval(lowPower: lowPower, tight: tight, active: active)
                    assert(
                        "lowPower=\(lowPower) tight=\(tight) active=\(active) -> \(Int(got))s >= \(Int(base))s",
                        got >= base
                    )
                }
            }
        }

        print()
        print("── an approval addressed to you may outrank the \"whose runs\" filter ──")
        // Only when the user asks for it. A colleague's deploy parked on YOUR
        // review is arguably not their run any more — you are the one holding
        // it up — but inside a company a reviewing team makes that true of
        // every deploy, so it is opt-in. When it is on the monitor picks the
        // dropped runs back up — but only for
        // `waiting`, the one status that can answer current_user_can_approve,
        // and only a few, because a queue of deploys behind one reviewer must
        // not turn into a request storm.
        func run(_ id: Int, _ status: RunStatus) -> WorkflowRun {
            WorkflowRun(id: id, status: status, repository: "acme/api")
        }
        let pool = [
            run(1, .waiting), run(2, .waiting), run(3, .inProgress),
            run(4, .actionRequired), run(5, .waiting), run(6, .success),
            run(7, .waiting), run(8, .waiting), run(9, .waiting), run(10, .waiting),
        ]
        let picked = RunMonitor.deploymentsAwaitingMe(in: pool, excluding: [], enabled: true)
        assert("only waiting runs are candidates",
               picked.allSatisfy { $0.status == .waiting })
        assert("a first-time-contributor gate is not a candidate — it has no reviewers",
               !picked.contains { $0.status == .actionRequired })
        assert("capped, so a queue behind one reviewer cannot storm the API",
               picked.count == 5)
        assert("runs the filter already kept are not fetched twice",
               RunMonitor.deploymentsAwaitingMe(
                   in: pool, excluding: Set(pool.map(\.identity)), enabled: true
               ).isEmpty)
        // The default. Inside an organization every colleague's deploy answers
        // current_user_can_approve, so an ungated version turned "Only my runs"
        // into everybody's runs.
        assert("off by default, the filter is absolute",
               RunMonitor.deploymentsAwaitingMe(
                   in: pool, excluding: [], enabled: false
               ).isEmpty)

        print()
        print("── and the one decision the island is drawn from ──")
        // `visibleRuns` is the single place both a poll and a settings change
        // go through. Two paths deciding this separately is how a colleague's
        // approval used to appear on one poll and vanish the moment any
        // unrelated setting was touched.
        func pending(_ canApprove: Bool) -> [PendingDeployment] {
            [PendingDeployment(
                environment: .init(id: 1, name: "production"),
                currentUserCanApprove: canApprove
            )]
        }
        func by(_ login: String, _ id: Int, waiting on: [PendingDeployment] = []) -> WorkflowRun {
            WorkflowRun(
                id: id,
                status: .waiting,
                actor: GitHubActor(login: login),
                repository: "acme/api",
                pendingDeployments: on
            )
        }
        let onlyMe = ActorFilter(logins: ["you"])
        let mixed = [
            by("you", 100),
            by("alice", 101, waiting: pending(true)),   // parked on YOUR review
            by("alice", 102, waiting: pending(false)),  // parked on somebody else's
        ]
        assert("off: only my runs, whoever the approval is addressed to",
               RunMonitor.visibleRuns(from: mixed, filter: onlyMe, approvalsFromOthers: false)
                   .map(\.id) == [100])
        assert("on: mine, plus the one addressed to me, never the other",
               RunMonitor.visibleRuns(from: mixed, filter: onlyMe, approvalsFromOthers: true)
                   .map(\.id).sorted() == [100, 101])
        assert("everyone: the opt-in changes nothing — nothing was hidden",
               RunMonitor.visibleRuns(from: mixed, filter: .everyone, approvalsFromOthers: false)
                   .count == mixed.count)
        assert("no run is shown twice when it is both mine and awaiting me",
               RunMonitor.visibleRuns(
                   from: [by("you", 200, waiting: pending(true))],
                   filter: onlyMe,
                   approvalsFromOthers: true
               ).count == 1)

        print()
        print("── a run waiting on a person still earns its job detail ──")
        // Its finished_at is whenever the pull request was opened, so the
        // two-minute window would have dropped it — and its job list is the
        // only thing that says WHICH job is blocked.
        assert("waiting run fetches jobs", RunMonitor.shouldFetchJobs(for: run(11, .waiting)))
        assert("action_required run fetches jobs",
               RunMonitor.shouldFetchJobs(for: run(12, .actionRequired)))
        assert("a run blocked on a person asks for its environments",
               RunMonitor.shouldFetchApprovals(for: run(13, .waiting)))
        assert("an ordinary running build does not",
               !RunMonitor.shouldFetchApprovals(for: run(14, .inProgress)))

        print()
        if failures == 0 {
            print("RESULT: PASS — cadence precedence holds on every combination checked")
        } else {
            print("RESULT: FAIL — \(failures) case(s) wrong")
            exit(1)
        }
    }
}
