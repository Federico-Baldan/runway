// Does Runway interrupt the right person?
//
// The approval feature has exactly one decision in it worth getting wrong: a
// run parked on a deployment reviewer is worth SHOWING everybody who can see
// the island, and worth NOTIFYING only the person GitHub says can unblock it.
// Get that backwards in a fifty-person organization and every colleague's
// deploy to production becomes a banner on your screen — which is how a status
// app gets muted in a week and never turned back on.
//
// `current_user_can_approve` is the field that decides it. Everything below
// pins the mapping from a real API payload to that decision, plus the two
// GitHub shapes that both mean "a person is the blocker" and look nothing alike
// in JSON:
//
//   status:     "waiting"           — a deploy job on a protected environment
//   conclusion: "action_required"   — a first-time contributor's PR, gated
//
//   swiftc -o /tmp/approval spike/ApprovalVerify.swift \
//       Sources/Runway/API/Models.swift Sources/Runway/API/Approvals.swift \
//       && /tmp/approval

import Foundation

@main
enum ApprovalVerify {
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

        func check(_ label: String, _ actual: ApprovalCheck.Verdict, _ expected: ApprovalCheck.Verdict) {
            if actual == expected {
                print("  ok    \(label)")
            } else {
                print("  FAIL  \(label) -> \(actual), expected \(expected)")
                failures += 1
            }
        }

        // MARK: The two statuses that mean "a person is the blocker"

        print("── both GitHub shapes read as waiting on a human ──")
        assert("status: waiting", RunStatus.resolve(status: "waiting", conclusion: nil).isAwaitingApproval)
        assert("conclusion: action_required",
               RunStatus.resolve(status: "completed", conclusion: "action_required").isAwaitingApproval)
        assert("in_progress is not an approval",
               !RunStatus.resolve(status: "in_progress", conclusion: nil).isAwaitingApproval)
        assert("failure is not an approval",
               !RunStatus.resolve(status: "completed", conclusion: "failure").isAwaitingApproval)
        assert("success is not an approval",
               !RunStatus.resolve(status: "completed", conclusion: "success").isAwaitingApproval)
        // The linger window in IslandModel keys off this: a terminal run ages
        // out, and an approval must not.
        assert("action_required is deliberately NOT terminal",
               !RunStatus.actionRequired.isTerminal)

        // MARK: The decision itself

        print()
        print("── who gets interrupted ──")

        let mine = run(status: .waiting, pending: [
            deployment("production", canApprove: true, reviewers: [("User", "you")]),
        ])
        check("GitHub says I can approve -> notify",
              mine.approval, .needsMe(environments: ["production"]))
        assert("and it is the only case that notifies", mine.awaitsMyApproval)

        let theirs = run(status: .waiting, pending: [
            deployment("production", canApprove: false, reviewers: [("User", "alice")]),
        ])
        check("somebody else's approval -> show, stay quiet",
              theirs.approval, .needsOthers(environments: ["production"], reviewers: ["alice"]))
        assert("no banner for a colleague's deploy", !theirs.awaitsMyApproval)
        assert("but the island still draws it", theirs.isBlockedOnApproval)

        let gated = run(status: .actionRequired, pending: [])
        check("first-time contributor gate, no environment detail",
              gated.approval, .blocked)
        assert("blocked without detail still shows", gated.isBlockedOnApproval)
        assert("blocked without detail never notifies", !gated.awaitsMyApproval)

        let building = run(status: .inProgress, pending: [])
        check("an ordinary running build is clear", building.approval, .clear)
        assert("clear is not blocked", !building.isBlockedOnApproval)

        // A run whose top-level status is still `in_progress` while one of its
        // jobs waits on a reviewer. This is the shape of EVERY build that has
        // reached its deploy stage, and reading the run's own status alone
        // draws it as "building" — which is exactly wrong, because nothing is.
        let deploying = WorkflowRun(
            id: 7, name: "deploy", runNumber: 12, status: .inProgress,
            repository: "acme/api",
            jobs: [
                Job(id: 1, name: "build", status: .success),
                Job(id: 2, name: "deploy", status: .waiting),
            ]
        )
        check("run in_progress, job waiting -> blocked", deploying.approval, .blocked)

        // Several environments at once: one of them mine.
        let mixed = run(status: .waiting, pending: [
            deployment("staging", canApprove: false, reviewers: [("User", "alice")]),
            deployment("production", canApprove: true, reviewers: [("Team", "platform")]),
        ])
        check("mine wins when several environments are pending",
              mixed.approval, .needsMe(environments: ["production"]))

        // `isBlockedOnApproval` and `awaitsMyApproval` do NOT go through the
        // verdict — they are read inside a sort comparator on every tick, and
        // going the long way allocated two arrays per call. Two answers to one
        // question is a bug waiting to happen, so it is pinned here.
        print()
        print("── the fast path agrees with the verdict it shortcuts ──")
        for (label, sample) in [("mine", mine), ("theirs", theirs), ("gated", gated),
                                ("building", building), ("deploying", deploying),
                                ("mixed", mixed)] {
            assert("\(label): isBlockedOnApproval matches the verdict",
                   sample.isBlockedOnApproval == sample.approval.isBlocked)
            assert("\(label): awaitsMyApproval matches the verdict",
                   sample.awaitsMyApproval == sample.approval.deservesNotification)
        }

        print()
        print("── the words the island and the banner share ──")
        assert("summary names the environment",
               mine.approvalSummary == "you can approve production")
        assert("summary names the reviewer",
               theirs.approvalSummary == "production — waiting for @alice")
        assert("summary degrades to something true",
               gated.approvalSummary == "waiting for approval")
        assert("a clear run has nothing to say", building.approvalSummary == nil)

        // MARK: Decoding a real payload

        print()
        print("── decoding GitHub's own response shape ──")
        let payload = Data("""
        [
          {
            "environment": {
              "id": 161088068, "node_id": "MDExOkVudmlyb25tZW50", "name": "staging",
              "url": "https://api.github.com/repos/o/r/environments/staging",
              "html_url": "https://github.com/o/r/deployments/activity_log"
            },
            "wait_timer": 30,
            "wait_timer_started_at": "2020-11-23T22:00:40Z",
            "current_user_can_approve": true,
            "reviewers": [
              { "type": "User", "reviewer": { "login": "octocat", "id": 1 } },
              { "type": "Team", "reviewer": { "name": "Justice League", "slug": "justice-league" } }
            ]
          }
        ]
        """.utf8)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let pending = try decoder.decode([PendingDeployment].self, from: payload)
            assert("one environment decoded", pending.count == 1)
            assert("environment name", pending.first?.environment.name == "staging")
            assert("wait timer", pending.first?.waitTimer == 30)
            assert("current_user_can_approve", pending.first?.currentUserCanApprove == true)
            assert("two reviewers", pending.first?.reviewers.count == 2)
            // A user is its login; a team is its SLUG, which is what GitHub's
            // own review dialog shows — not the display name beside it.
            assert("user reviewer is its login",
                   pending.first?.reviewers.first?.name == "octocat")
            assert("team reviewer is its slug",
                   pending.first?.reviewers.last?.name == "justice-league")
            assert("team is typed as a team",
                   pending.first?.reviewers.last?.kind == .team)
        } catch {
            print("  FAIL  payload did not decode: \(error)")
            failures += 1
        }

        // A response missing every optional field must not throw: this endpoint
        // is documented loosely and a decode failure here would take out the
        // whole poll for one environment name.
        let sparse = Data(#"[{"environment":{"name":"prod"},"reviewers":[]}]"#.utf8)
        do {
            let pending = try decoder.decode([PendingDeployment].self, from: sparse)
            assert("sparse payload decodes", pending.first?.environment.name == "prod")
            assert("missing current_user_can_approve defaults to false, never true",
                   pending.first?.currentUserCanApprove == false)
        } catch {
            print("  FAIL  sparse payload threw: \(error)")
            failures += 1
        }

        // MARK: Progress

        print()
        print("── the ring the glyph draws ──")
        let half = WorkflowRun(
            id: 9, status: .inProgress, repository: "acme/web",
            jobs: [Job(id: 1, name: "test", status: .inProgress, steps: [
                Step(name: "a", number: 1, status: .success),
                Step(name: "b", number: 2, status: .success),
                Step(name: "c", number: 3, status: .inProgress),
                Step(name: "d", number: 4, status: .queued),
            ])]
        )
        assert("two of four steps settled -> 0.5", half.progress == 0.5)
        assert("no jobs yet -> 0", building.progress == 0)

        print()
        if failures == 0 {
            print("RESULT: PASS — approvals reach the person who can act on them")
        } else {
            print("RESULT: FAIL — \(failures) case(s) wrong")
            exit(1)
        }
    }

    // MARK: - Fixtures

    static func run(status: RunStatus, pending: [PendingDeployment]) -> WorkflowRun {
        WorkflowRun(
            id: 42,
            name: "deploy",
            runNumber: 7,
            headBranch: "main",
            status: status,
            repository: "acme/web-app",
            pendingDeployments: pending
        )
    }

    static func deployment(
        _ name: String,
        canApprove: Bool,
        reviewers: [(String, String)]
    ) -> PendingDeployment {
        PendingDeployment(
            environment: PendingDeployment.Environment(id: name.hashValue, name: name),
            waitTimer: 0,
            waitTimerStartedAt: nil,
            currentUserCanApprove: canApprove,
            reviewers: reviewers.map {
                DeploymentReviewer(kind: DeploymentReviewer.Kind(rawValue: $0.0) ?? .unknown, name: $0.1)
            }
        )
    }
}
