// What does a poll actually SPEND, and on which runs?
//
// Three static gates in `RunMonitor` decide that, and between them they are the
// whole difference between a poll that costs one request per repository and one
// that costs four. `docs/polling.md` does the arithmetic on the assumption that
// they hold; nothing checked that they do.
//
// `shouldFetchReviewHistory` had no coverage at all, and it is the one with the
// least forgiving arithmetic: a failed run lingers on the island for ten
// minutes, so a gate that answers `true` twice puts a request on every red run
// on screen, every tick, for that whole window. Its "ask once, ever" rule is
// what stands between a rejection being recognised and the island's red runs
// costing more than its live ones.
//
//   swiftc -o /tmp/gates spike/RequestGateVerify.swift \
//       Sources/Runway/Core/RunMonitor.swift Sources/Runway/API/GitHubClient.swift \
//       Sources/Runway/API/Models.swift Sources/Runway/API/Approvals.swift \
//       Sources/Runway/API/DeployTarget.swift Sources/Runway/API/RunScope.swift \
//       Sources/Runway/API/ETagStore.swift Sources/Runway/Auth/Keychain.swift \
//       && /tmp/gates

import Foundation

@main
enum RequestGateVerify {
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

        let now = Date()

        /// A finished run that stopped `ago` seconds back. `finishedAt` reads
        /// `updatedAt`, and only for a run whose status is not active.
        func finished(_ status: RunStatus, ago: TimeInterval, jobs: [Job] = []) -> WorkflowRun {
            WorkflowRun(
                id: 1,
                status: status,
                updatedAt: now.addingTimeInterval(-ago),
                repository: "acme/api",
                jobs: jobs
            )
        }

        func job(_ status: RunStatus, steps: [Step]) -> Job {
            Job(id: 1, name: "deploy", status: status, steps: steps)
        }

        let aStep = Step(name: "Run terraform apply", number: 1, status: .failure)

        print("── shouldFetchJobs: the two-minute window ──")
        // Job detail is one request per run. Fetching it for everything roughly
        // doubles the poll, so it is limited to runs that are moving or freshly
        // finished — the only ones the island draws detail for.
        assert("a running build earns its detail",
               RunMonitor.shouldFetchJobs(for: WorkflowRun(id: 1, status: .inProgress), now: now))
        assert("so does one that finished thirty seconds ago",
               RunMonitor.shouldFetchJobs(for: finished(.success, ago: 30), now: now))
        assert("a run that finished five minutes ago does NOT — this is the rule "
               + "that stops a lingering red run costing a request every tick",
               !RunMonitor.shouldFetchJobs(for: finished(.failure, ago: 300), now: now))
        assert("and one with no finish time at all does not either",
               !RunMonitor.shouldFetchJobs(for: WorkflowRun(id: 1, status: .success), now: now))

        print()
        print("── shouldFetchReviewHistory: ask once, ever ──")
        // The endpoint is only ever asked about a FINISHED run, whose review
        // history cannot change again — so a second request could only return
        // the first one's answer. `alreadyAsked` is what makes that hold, and
        // an entry in the cache doubles as the marker, empty array included.
        let rejectionShaped = finished(.failure, ago: 60, jobs: [job(.failure, steps: [])])
        assert("a failure whose job is red with no steps looks like a rejection",
               RunMonitor.shouldFetchReviewHistory(for: rejectionShaped, alreadyAsked: false))
        assert("but never twice — this is the whole budget",
               !RunMonitor.shouldFetchReviewHistory(for: rejectionShaped, alreadyAsked: true))

        print()
        print("── and only for the shapes a rejection can arrive in ──")
        assert("an ordinary breakage has the steps that broke, so it is not asked about",
               !RunMonitor.shouldFetchReviewHistory(
                   for: finished(.failure, ago: 60, jobs: [job(.failure, steps: [aStep])]),
                   alreadyAsked: false))
        assert("a success is never asked about",
               !RunMonitor.shouldFetchReviewHistory(
                   for: finished(.success, ago: 60), alreadyAsked: false))
        // `isFailure` is wider than `.failure`, and only `.failure` is the
        // conclusion GitHub uses for a turned-down deployment.
        assert("a timeout is a failure but not THE failure, so it is not asked about",
               !RunMonitor.shouldFetchReviewHistory(
                   for: finished(.timedOut, ago: 60), alreadyAsked: false))
        assert("a run already relabelled as rejected does not ask again",
               !RunMonitor.shouldFetchReviewHistory(
                   for: finished(.rejected, ago: 60), alreadyAsked: false))

        print()
        print("── the cold-start branch: no jobs to corroborate with ──")
        // A run that failed before the app opened is past shouldFetchJobs's
        // window but still inside the ten minutes the island shows failures
        // for. There is nothing to test against, so it falls back to the
        // weakest honest question: does this run look like it deploys anywhere?
        let deploying = WorkflowRun(
            id: 1,
            name: "deploy production",
            status: .failure,
            updatedAt: now.addingTimeInterval(-300),
            repository: "acme/api"
        ).stampingDeployTarget()
        assert("a deploy that failed before launch is worth one question",
               deploying.deployTarget != nil
                   && RunMonitor.shouldFetchReviewHistory(for: deploying, alreadyAsked: false))

        let plainBuild = WorkflowRun(
            id: 1,
            name: "unit tests",
            status: .failure,
            updatedAt: now.addingTimeInterval(-300),
            repository: "acme/api"
        ).stampingDeployTarget()
        assert("a build that deploys nowhere cannot have been rejected, so it is "
               + "never asked — this is what keeps ordinary red runs free",
               plainBuild.deployTarget == nil
                   && !RunMonitor.shouldFetchReviewHistory(for: plainBuild, alreadyAsked: false))

        print()
        print("── shouldFetchApprovals: only what has said it is waiting ──")
        // The endpoint answers [] for every run that is not blocked, so asking
        // speculatively spends one request per run per poll to learn nothing.
        assert("a run whose JOB waits, while the run says in_progress, still asks — "
               + "that is the shape of a build that reached its deploy stage",
               RunMonitor.shouldFetchApprovals(
                   for: WorkflowRun(
                       id: 1, status: .inProgress, repository: "acme/api",
                       jobs: [job(.waiting, steps: [])]
                   )))
        assert("a finished run does not",
               !RunMonitor.shouldFetchApprovals(for: finished(.success, ago: 10)))

        print()
        print("── the watch list: one repository, one request ──")
        // GitHub does not distinguish `acme/api` from `acme/API`, and this list
        // is taken verbatim from Settings or `RUNWAY_REPOS`. Two entries meant
        // two polls a cycle for one repository — and worse, `fetchRuns` stamps
        // the configured spelling onto every run, so one build came back under
        // two identities and the island drew it twice.
        func repo(_ name: String) -> Repository { Repository(fullName: name) }

        assert("the same repository in two spellings is polled once",
               RunMonitor.watchList(
                   for: [repo("acme/api"), repo("acme/API")], carryingOver: []
               ).count == 1)
        assert("and it keeps the spelling it arrived with, which is what goes in the URL",
               RunMonitor.watchList(
                   for: [repo("acme/API"), repo("acme/api")], carryingOver: []
               ).first?.fullName == "acme/API")
        assert("an exact duplicate is still dropped",
               RunMonitor.watchList(
                   for: [repo("acme/api"), repo("acme/api")], carryingOver: []
               ).count == 1)
        assert("two genuinely different repositories both survive",
               RunMonitor.watchList(
                   for: [repo("acme/api"), repo("acme/web")], carryingOver: []
               ).count == 2)
        // A repo demoted for having no Actions must not be promoted back on
        // every five-minute rediscovery.
        assert("what the last list learned is carried across the refresh",
               RunMonitor.watchList(
                   for: [repo("acme/api")],
                   carryingOver: [WatchedRepo(fullName: "acme/api", hasWorkflows: false)]
               ).first?.hasWorkflows == false)

        print()
        if failures == 0 {
            print("RESULT: PASS — a poll spends only what the budget says it does")
        } else {
            print("RESULT: FAIL — \(failures) gate(s) wrong")
            exit(1)
        }
    }
}
