// Is a rejected deploy a failure?
//
// GitHub says yes. It reports a deployment a required reviewer turned down as
// `conclusion: "failure"` — indistinguishable, in the runs list, from a build
// that fell over — and Runway drew it as a red cross for exactly as long as it
// believed that field. The person who had *just clicked reject themselves* got
// an alarm about their own decision.
//
// The truth is on `/actions/runs/{id}/approvals`, where the same event reads
// `state: "rejected"` with the reviewer and their comment attached. This pins
// the round trip: that payload in, `RunStatus.rejected` out, and — the part
// that actually keeps people safe — every shape that must NOT be relabelled.
//
//   swiftc -o /tmp/rejection spike/RejectionVerify.swift \
//       Sources/Runway/API/Models.swift Sources/Runway/API/Approvals.swift \
//       Sources/Runway/API/DeployTarget.swift && /tmp/rejection

import Foundation

@main
enum RejectionVerify {
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

        // MARK: The state itself

        print("── a rejection is settled, and is not a breakage ──")
        assert("not a failure", !RunStatus.rejected.isFailure)
        assert("terminal", RunStatus.rejected.isTerminal)
        assert("not active", !RunStatus.rejected.isActive)
        assert("not waiting on anybody — it has been answered",
               !RunStatus.rejected.isAwaitingApproval)
        assert("reads as \"rejected\"", RunStatus.rejected.label == "rejected")
        // The whole reason the case is stamped rather than decoded: GitHub has
        // no such conclusion, and never sends one.
        assert("never comes out of the wire format",
               RunStatus.resolve(status: "completed", conclusion: "rejected") == .unknown)
        assert("a real rejection arrives as a failure",
               RunStatus.resolve(status: "completed", conclusion: "failure") == .failure)

        // MARK: Decoding the review history

        print()
        print("── GET /actions/runs/{id}/approvals ──")

        let payload = Data("""
        [
          {
            "environments": [
              { "id": 161088068, "name": "preprod",
                "html_url": "https://github.com/o/r/deployments/activity_log" }
            ],
            "state": "rejected",
            "user": { "login": "octocat", "avatar_url": "https://a/u/1" },
            "comment": "not on a Friday"
          }
        ]
        """.utf8)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var history: [DeploymentReview] = []
        do {
            history = try decoder.decode([DeploymentReview].self, from: payload)
            assert("one review decoded", history.count == 1)
            assert("state", history.first?.state == .rejected)
            assert("who", history.first?.user?.login == "octocat")
            assert("comment", history.first?.comment == "not on a Friday")
            assert("environment", history.first?.environments.first?.name == "preprod")
            assert("handle", history.first?.handle == "@octocat")
        } catch {
            print("  FAIL  payload did not decode: \(error)")
            failures += 1
        }

        // An unknown state must not throw. A new value on this endpoint taking
        // out the decode would take the whole review history with it, and a run
        // drawn as a plain failure is a far better outcome than a poll that
        // errors — which is precisely what the app did before any of this.
        do {
            let odd = Data(#"[{"state":"escalated"}]"#.utf8)
            let reviews = try decoder.decode([DeploymentReview].self, from: odd)
            assert("unknown state decodes rather than throwing",
                   reviews.first?.state == .unknown)
            assert("missing user is nil, not a crash", reviews.first?.user == nil)
            assert("missing comment is empty", reviews.first?.comment == "")
        } catch {
            print("  FAIL  sparse payload threw: \(error)")
            failures += 1
        }

        // MARK: The relabelling, and everything it must leave alone

        print()
        print("── what gets relabelled ──")

        // The shape from the screenshot that started this: terraform-scan and
        // terraform-plan passed, terraform-apply is red with no steps in it
        // because it never ran.
        var rejected = run(
            .failure,
            jobs: [
                job("terraform-scan", .success, steps: 9),
                job("terraform-plan", .success, steps: 16),
                job("terraform-apply", .failure, steps: 0),
            ],
            reviews: history
        )
        rejected.stampRejection()
        assert("a turned-down deploy stops being a failure", rejected.status == .rejected)
        assert("and stops counting as one", !rejected.status.isFailure)
        assert("the gate job is relabelled too",
               rejected.jobs.last?.status == .rejected)
        assert("the jobs that really ran are untouched",
               rejected.jobs.first?.status == .success)
        assert("it names the person", rejected.rejectedBy == "octocat")
        assert("and keeps their comment", rejected.rejectionComment == "not on a Friday")
        assert("summary reads as a sentence",
               rejected.rejectionSummary == "@octocat rejected the deploy to preprod")

        // The one that matters. `/approvals` is keyed on the run **id**, not the
        // attempt, so a run rejected on attempt 1 and re-run into a genuine
        // terraform failure on attempt 2 still answers `rejected` — and calling
        // that a rejection would hide a broken production deploy behind a grey
        // glyph. The failing job has steps in it, so it is not a gate.
        var reallyBroke = run(
            .failure,
            jobs: [
                job("terraform-plan", .success, steps: 16),
                job("terraform-apply", .failure, steps: 7),
            ],
            reviews: history
        )
        reallyBroke.stampRejection()
        assert("a run that broke on a later attempt stays a failure",
               reallyBroke.status == .failure)
        assert("its red job stays red", reallyBroke.jobs.last?.status == .failure)
        assert("and it says nothing about a rejection", reallyBroke.rejectedBy == nil)

        // A history with nothing but approvals in it describes a deploy that
        // went ahead and then broke on its own.
        var approvedThenBroke = run(
            .failure,
            jobs: [job("deploy", .failure, steps: 0)],
            reviews: [DeploymentReview(state: .approved, user: GitHubActor(login: "octocat"))]
        )
        approvedThenBroke.stampRejection()
        assert("an approval is not a rejection", approvedThenBroke.status == .failure)

        // Nothing that is not already red is ever rewritten.
        for status in [RunStatus.success, .cancelled, .inProgress, .waiting, .skipped] {
            var other = run(status, jobs: [job("deploy", status, steps: 0)], reviews: history)
            other.stampRejection()
            assert("\(status.rawValue) is left alone", other.status == status)
        }

        // Cold start: the run is in the list, its jobs are not. There is
        // nothing to corroborate with, and a rejection is still the better
        // answer than a cross nobody can explain.
        var noDetail = run(.failure, jobs: [], reviews: history)
        noDetail.stampRejection()
        assert("a run with no job detail yet still gets the truth",
               noDetail.status == .rejected)

        // MARK: The signature

        print()
        print("── the island is told about it ──")
        var before = run(.failure, jobs: [job("deploy", .failure, steps: 0)], reviews: [])
        let stale = before.signature
        before.reviews = history
        before.stampRejection()
        assert("relabelling moves the run's signature", before.signature != stale)

        print()
        if failures == 0 {
            print("RESULT: PASS — a decision is not a failure")
        } else {
            print("RESULT: FAIL — \(failures) case(s) wrong")
            exit(1)
        }
    }

    // MARK: Fixtures

    static func run(
        _ status: RunStatus,
        jobs: [Job],
        reviews: [DeploymentReview]
    ) -> WorkflowRun {
        var value = WorkflowRun(
            id: 71,
            name: "syo_services_infrastructure",
            runNumber: 71,
            status: status,
            repository: "satispay-tech/syo_services_infrastructure",
            jobs: jobs,
            reviews: reviews
        )
        value.stampDeployTarget()
        return value
    }

    static func job(_ name: String, _ status: RunStatus, steps: Int) -> Job {
        Job(
            id: abs(name.hashValue % 100_000),
            name: name,
            status: status,
            steps: (0..<steps).map {
                Step(name: "step \($0)", number: $0 + 1, status: .success)
            }
        )
    }
}
