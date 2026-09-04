// Does RunStatus.resolve() actually collapse GitHub's status/conclusion pair
// correctly?
//
// This is the single most breakable assumption in the port. GitLab returned one
// `status` field; GitHub returns two, and every finished run reports
// `status: "completed"` regardless of whether it passed or exploded. Reading
// `status` alone makes green and red identical — the island would show a
// cheerful blue dot for a failed deploy.
//
// The pairs below are the ones the REST API actually emits, taken from the
// documented enum for /repos/{owner}/{repo}/actions/runs.
//
//   swiftc -o /tmp/statusfusion spike/StatusFusionVerify.swift \
//       Sources/Runway/API/Models.swift && /tmp/statusfusion

import Foundation

@main
enum StatusFusionVerify {
    static func main() {
        var failures = 0

        func check(_ label: String, _ actual: RunStatus, _ expected: RunStatus) {
            if actual == expected {
                print("  ok    \(label) -> \(actual.rawValue)")
            } else {
                print("  FAIL  \(label) -> \(actual.rawValue), expected \(expected.rawValue)")
                failures += 1
            }
        }

        func assert(_ label: String, _ condition: Bool) {
            if condition {
                print("  ok    \(label)")
            } else {
                print("  FAIL  \(label)")
                failures += 1
            }
        }

        print("── in-flight: conclusion is null, status carries the state ──")
        check("queued/null",      RunStatus.resolve(status: "queued", conclusion: nil), .queued)
        check("in_progress/null", RunStatus.resolve(status: "in_progress", conclusion: nil), .inProgress)
        check("waiting/null",     RunStatus.resolve(status: "waiting", conclusion: nil), .waiting)
        check("requested/null",   RunStatus.resolve(status: "requested", conclusion: nil), .requested)
        check("pending/null",     RunStatus.resolve(status: "pending", conclusion: nil), .pending)

        print()
        print("── finished: status is always \"completed\", conclusion decides ──")
        check("completed/success",        RunStatus.resolve(status: "completed", conclusion: "success"), .success)
        check("completed/failure",        RunStatus.resolve(status: "completed", conclusion: "failure"), .failure)
        check("completed/cancelled",      RunStatus.resolve(status: "completed", conclusion: "cancelled"), .cancelled)
        check("completed/skipped",        RunStatus.resolve(status: "completed", conclusion: "skipped"), .skipped)
        check("completed/neutral",        RunStatus.resolve(status: "completed", conclusion: "neutral"), .neutral)
        check("completed/timed_out",      RunStatus.resolve(status: "completed", conclusion: "timed_out"), .timedOut)
        check("completed/action_required",RunStatus.resolve(status: "completed", conclusion: "action_required"), .actionRequired)
        check("completed/startup_failure",RunStatus.resolve(status: "completed", conclusion: "startup_failure"), .startupFailure)
        check("completed/stale",          RunStatus.resolve(status: "completed", conclusion: "stale"), .stale)

        print()
        print("── the trap: conclusion must win even when status says completed ──")
        assert("a failed run is NOT active",
               !RunStatus.resolve(status: "completed", conclusion: "failure").isActive)
        assert("a failed run reads as a failure",
               RunStatus.resolve(status: "completed", conclusion: "failure").isFailure)
        assert("a successful run is not a failure",
               !RunStatus.resolve(status: "completed", conclusion: "success").isFailure)
        assert("timed_out counts as a failure, not a neutral end",
               RunStatus.resolve(status: "completed", conclusion: "timed_out").isFailure)
        assert("startup_failure counts as a failure",
               RunStatus.resolve(status: "completed", conclusion: "startup_failure").isFailure)
        assert("cancelled is NOT a failure — nobody wants a red island for their own ^C",
               !RunStatus.resolve(status: "completed", conclusion: "cancelled").isFailure)
        assert("skipped is not a failure",
               !RunStatus.resolve(status: "completed", conclusion: "skipped").isFailure)

        print()
        print("── action_required must stay non-terminal ──")
        // A run parked on a deployment approval is 'completed' to the API but WILL
        // move again when somebody clicks approve. Treating it as terminal would let
        // the island retire it and never notice the deploy that follows.
        assert("action_required is not terminal",
               !RunStatus.resolve(status: "completed", conclusion: "action_required").isTerminal)
        assert("success is terminal",
               RunStatus.resolve(status: "completed", conclusion: "success").isTerminal)
        assert("failure is terminal",
               RunStatus.resolve(status: "completed", conclusion: "failure").isTerminal)

        print()
        print("── degenerate input must not crash or lie ──")
        check("nil/nil",            RunStatus.resolve(status: nil, conclusion: nil), .unknown)
        check("garbage/nil",        RunStatus.resolve(status: "wat", conclusion: nil), .unknown)
        check("completed/nil",      RunStatus.resolve(status: "completed", conclusion: nil), .unknown)
        check("completed/empty",    RunStatus.resolve(status: "completed", conclusion: ""), .unknown)
        check("IN_PROGRESS upper",  RunStatus.resolve(status: "IN_PROGRESS", conclusion: nil), .inProgress)
        check("canceled US spelling", RunStatus.resolve(status: "completed", conclusion: "canceled"), .cancelled)
        assert("unknown is neither active nor terminal, so it is polled again",
               !RunStatus.unknown.isActive && !RunStatus.unknown.isTerminal)

        print()
        print("── which job the pill names ──")
        // `isActive` answers the cadence's question — is this run going
        // anywhere — and says yes to queued. Naming a job is a different
        // question, and on a matrix build the two pick different jobs: every
        // shard is created queued, and runners take them in whatever order
        // they free up.
        func job(_ name: String, _ status: RunStatus) -> Job {
            Job(id: abs(name.hashValue % 100_000), name: name, status: status)
        }
        func run(_ jobs: [Job]) -> WorkflowRun {
            WorkflowRun(id: 1, status: .inProgress, repository: "acme/api", jobs: jobs)
        }
        assert("a shard actually running outranks one still waiting for a runner",
               run([job("shard-1", .queued), job("shard-2", .inProgress)])
                   .firstRunningJob?.name == "shard-2")
        assert("and order still decides between two that are both running",
               run([job("build", .inProgress), job("test", .inProgress)])
                   .firstRunningJob?.name == "build")
        assert("a run that is entirely queued still names something — waiting "
               + "for a runner is worth saying",
               run([job("shard-1", .queued), job("shard-2", .queued)])
                   .firstRunningJob?.name == "shard-1")
        assert("a finished job is never named",
               run([job("build", .success), job("test", .failure)]).firstRunningJob == nil)
        assert("and a job parked on a person counts as active, not as running",
               run([job("deploy", .waiting), job("build", .inProgress)])
                   .firstRunningJob?.name == "build")

        print()
        print("── what counts as a re-run ──")
        func who(_ login: String) -> GitHubActor { GitHubActor(login: login) }
        func attempt(_ n: Int, actor: GitHubActor?, triggering: GitHubActor?) -> WorkflowRun {
            WorkflowRun(id: 1, runAttempt: n, status: .success,
                        actor: actor, triggeringActor: triggering, repository: "acme/api")
        }
        assert("a second attempt is a re-run whoever pushed it",
               attempt(2, actor: who("alice"), triggering: who("alice")).isRerun)
        assert("and so is somebody else's finger on the button",
               attempt(1, actor: who("alice"), triggering: who("bob")).isRerun)
        assert("one person's own first attempt is not",
               !attempt(1, actor: who("alice"), triggering: who("alice")).isRerun)
        // The false positive: comparing through the optionals made a missing
        // `actor` compare unequal to a present `triggering_actor`, so a first
        // attempt was drawn with the re-run arrow.
        assert("a missing actor is not evidence of a second person",
               !attempt(1, actor: nil, triggering: who("bob")).isRerun)
        assert("nor is a missing triggering actor",
               !attempt(1, actor: who("alice"), triggering: nil).isRerun)
        assert("nor both missing", !attempt(1, actor: nil, triggering: nil).isRerun)

        print()
        if failures == 0 {
            print("RESULT: PASS — status fusion holds for every documented pair")
        } else {
            print("RESULT: FAIL — \(failures) case(s) wrong")
            exit(1)
        }
    }
}
