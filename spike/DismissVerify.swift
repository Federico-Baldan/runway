// Can you get a run off the island, and does it stay off?
//
// The island decides what to show from rules — is it moving, did it break, is
// somebody waiting on you — and the rules are right nearly all of the time.
// Dismissal is the escape hatch for the rest, and an escape hatch has exactly
// two ways to be worse than useless: letting the thing back in, and forgetting
// to let go of it.
//
// Nothing here touches GitHub. Dismissal is local by design — Runway's token
// is read-only, the same reason it shows you an approval and sends you to
// GitHub to grant it — so what is pinned below is the filter and the retention
// rule, which is the whole of the feature.
//
//   swiftc -o /tmp/dismiss spike/DismissVerify.swift \
//       Sources/Runway/Core/DismissedRuns.swift \
//       Sources/Runway/Core/RunMonitor.swift … && /tmp/dismiss

import Foundation

@main
enum DismissVerify {
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

        let mine = ActorFilter.resolve(scope: .me, watched: ["@me"], currentUser: "octocat")

        let building = run(1, "octocat", .inProgress)
        let broke = run(2, "octocat", .failure)
        let waiting = run(3, "colleague", .waiting, awaitingMe: true)
        let all = [building, broke, waiting]

        // MARK: The filter

        print("── a dismissed run is gone from every view of the state ──")
        let none = RunMonitor.visibleRuns(from: all, filter: mine, approvalsFromOthers: true)
        assert("all three visible to begin with", none.count == 3)

        let hidden = RunMonitor.visibleRuns(
            from: all, filter: mine, approvalsFromOthers: true,
            dismissed: [broke.identity]
        )
        assert("the dismissed one is gone", hidden.count == 2)
        assert("and it is the right one",
               !hidden.contains { $0.identity == broke.identity })
        assert("the others are untouched",
               hidden.contains { $0.identity == building.identity })

        // The rule that has to outrank the others. `approvalsFromOthers` exists
        // to put a colleague's run back on the island when it is parked on your
        // review — and a run you have explicitly dismissed must not come back
        // through that door, or the × reads as broken.
        let hiddenApproval = RunMonitor.visibleRuns(
            from: all, filter: mine, approvalsFromOthers: true,
            dismissed: [waiting.identity]
        )
        assert("a dismissal outranks the approval opt-in",
               !hiddenApproval.contains { $0.identity == waiting.identity })

        // Same under "Everyone's runs", which returns early on its own path.
        let everyone = RunMonitor.visibleRuns(
            from: all, filter: .everyone, approvalsFromOthers: false,
            dismissed: [broke.identity]
        )
        assert("a dismissal outranks \"everyone's runs\" too", everyone.count == 2)

        assert("no dismissals changes nothing",
               RunMonitor.visibleRuns(from: all, filter: .everyone,
                                      approvalsFromOthers: false).count == 3)

        // MARK: Identity

        print()
        print("── what exactly was dismissed ──")
        // The identity carries the attempt, so re-running a run you dismissed
        // brings the new attempt back. That is the intended behaviour: the
        // thing being hidden is a result, and a re-run is a different result.
        let secondAttempt = WorkflowRun(
            id: broke.id, runNumber: broke.runNumber, runAttempt: 2,
            status: .inProgress,
            actor: GitHubActor(login: "octocat"),
            repository: broke.repository
        )
        assert("a re-run is a different identity",
               secondAttempt.identity != broke.identity)
        assert("so it comes back",
               RunMonitor.visibleRuns(
                   from: [secondAttempt], filter: mine, approvalsFromOthers: false,
                   dismissed: [broke.identity]
               ).count == 1)

        // MARK: Retention

        print()
        print("── a dismissal lets go of itself ──")
        let now = Date()
        let stamp = now.timeIntervalSinceReferenceDate
        let stored: [String: Double] = [
            "fresh": stamp - 60,
            "yesterday": stamp - 24 * 60 * 60,
            "a fortnight and a minute ago": stamp - DismissedRuns.retention - 60,
        ]
        let live = DismissedRuns.prune(stored, now: now)
        assert("today's dismissal survives", live["fresh"] != nil)
        assert("yesterday's dismissal survives", live["yesterday"] != nil)
        // The identity carries a run id, so the store mints a new key every
        // time and would otherwise grow for the life of the installation.
        assert("an expired one is dropped",
               live["a fortnight and a minute ago"] == nil)
        assert("exactly one was dropped", live.count == 2)
        assert("an empty store prunes to empty",
               DismissedRuns.prune([:], now: now).isEmpty)

        print()
        if failures == 0 {
            print("RESULT: PASS — dismissed runs stay dismissed, and expire on their own")
        } else {
            print("RESULT: FAIL — \(failures) case(s) wrong")
            exit(1)
        }
    }

    static func run(
        _ id: Int,
        _ login: String,
        _ status: RunStatus,
        awaitingMe: Bool = false
    ) -> WorkflowRun {
        WorkflowRun(
            id: id,
            name: "deploy",
            runNumber: id,
            status: status,
            actor: GitHubActor(login: login),
            repository: "acme/app",
            pendingDeployments: awaitingMe
                ? [PendingDeployment(
                    environment: PendingDeployment.Environment(id: 1, name: "production"),
                    currentUserCanApprove: true
                )]
                : []
        )
    }
}
