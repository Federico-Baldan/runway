// Does a run survive being written down and read back?
//
// Nothing in the app encodes a WorkflowRun today — the poll decodes GitHub's
// JSON and keeps the value in memory — and that is exactly why this was wrong
// for so long without anybody noticing. The types conform to `Codable`, which
// is a promise, and the promise was broken in the one place it is easiest to
// break: the decoders read GitHub's TWO-field vocabulary (`status` +
// `conclusion`, fused by `RunStatus.resolve`), while the hand-written encoders
// wrote Swift's own case name under `status` and nothing under `conclusion`.
//
//   .success  ->  {"status": "success"}  ->  resolve("success", nil)  ->  .unknown
//
// So every finished run came back not merely wrong but *uniformly* wrong: green,
// red and cancelled all decoded to the same grey `.unknown`. The first feature
// to persist runs across launches, or to put one in a pasteboard, would have
// inherited that silently.
//
// `RunStatus.wireValues` is the inverse `resolve` never had, and this pins it.
//
//   swiftc -o /tmp/codable spike/CodableVerify.swift \
//       Sources/Runway/API/Models.swift Sources/Runway/API/Approvals.swift \
//       Sources/Runway/API/DeployTarget.swift && /tmp/codable

import Foundation

@main
enum CodableVerify {
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

        func check(_ label: String, _ actual: RunStatus, _ expected: RunStatus) {
            if actual == expected {
                print("  ok    \(label) -> \(actual.rawValue)")
            } else {
                print("  FAIL  \(label) -> \(actual.rawValue), expected \(expected.rawValue)")
                failures += 1
            }
        }

        // Whole seconds, so an ISO-8601 round trip is lossless and a date
        // comparison below is testing the encoder rather than sub-second drift.
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        func roundTrip<T: Codable>(_ value: T) -> T? {
            guard let data = try? encoder.encode(value) else { return nil }
            return try? decoder.decode(T.self, from: data)
        }

        // `.rejected` is Runway's own reading of a payload that says `failure`,
        // stamped on afterwards by `stampRejection()` from a review history that
        // arrives in a different response and is not part of what any of these
        // encoders write. So it is the one case that is expected to come back as
        // what GitHub actually sent, rather than as itself.
        func expected(after status: RunStatus) -> RunStatus {
            status == .rejected ? .failure : status
        }

        print("── wireValues is the inverse of resolve ──")
        for status in RunStatus.allCases {
            let wire = status.wireValues
            check(
                "\(status.rawValue) -> (\(wire.status), \(wire.conclusion ?? "null"))",
                RunStatus.resolve(status: wire.status, conclusion: wire.conclusion),
                expected(after: status)
            )
        }

        print()
        print("── and it speaks GitHub's vocabulary, not Swift's ──")
        assert("in_progress, not inProgress", RunStatus.inProgress.wireValues.status == "in_progress")
        assert("timed_out, not timedOut", RunStatus.timedOut.wireValues.conclusion == "timed_out")
        assert("action_required, not actionRequired",
               RunStatus.actionRequired.wireValues.conclusion == "action_required")
        assert("startup_failure, not startupFailure",
               RunStatus.startupFailure.wireValues.conclusion == "startup_failure")
        assert("a finished run always reports status: completed",
               RunStatus.success.wireValues.status == "completed"
                   && RunStatus.failure.wireValues.status == "completed"
                   && RunStatus.cancelled.wireValues.status == "completed")
        assert("an in-flight run carries no conclusion, exactly as GitHub sends it",
               RunStatus.queued.wireValues.conclusion == nil
                   && RunStatus.inProgress.wireValues.conclusion == nil
                   && RunStatus.waiting.wireValues.conclusion == nil)

        print()
        print("── the regression itself: JSON a stranger could read ──")
        let finished = WorkflowRun(id: 1, runNumber: 7, status: .success)
        guard let data = try? encoder.encode(finished),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("  FAIL  a run would not encode at all")
            exit(1)
        }
        assert("status is \"completed\", the way the API says it",
               object["status"] as? String == "completed")
        assert("the outcome is in `conclusion`, where every decoder looks for it",
               object["conclusion"] as? String == "success")
        assert("and NOT the Swift case name under `status` — the old bug",
               object["status"] as? String != "success")

        print()
        print("── every status survives a WorkflowRun round trip ──")
        for status in RunStatus.allCases {
            let run = WorkflowRun(
                id: 42,
                name: "build",
                path: ".github/workflows/build.yml",
                displayTitle: "Update main",
                runNumber: 562,
                runAttempt: 2,
                headBranch: "main",
                headSHA: "cafe",
                event: "push",
                status: status,
                htmlURL: "https://github.com/acme/web/actions/runs/42",
                createdAt: stamp,
                updatedAt: stamp,
                runStartedAt: stamp,
                actor: GitHubActor(login: "you"),
                triggeringActor: GitHubActor(login: "alice")
            )
            guard let back = roundTrip(run) else {
                print("  FAIL  \(status.rawValue) did not survive the trip at all")
                failures += 1
                continue
            }
            check("run \(status.rawValue)", back.status, expected(after: status))
        }

        print()
        print("── and the rest of the run comes back with it ──")
        let full = WorkflowRun(
            id: 90_100,
            name: "deploy",
            path: ".github/workflows/deploy.yml",
            displayTitle: "Ship it",
            runNumber: 562,
            runAttempt: 3,
            headBranch: "release/2.4",
            headSHA: "beef",
            event: "workflow_dispatch",
            status: .failure,
            htmlURL: "https://github.com/acme/web/actions/runs/90100",
            createdAt: stamp,
            updatedAt: stamp,
            runStartedAt: stamp,
            actor: GitHubActor(login: "you"),
            triggeringActor: GitHubActor(login: "alice")
        )
        if let back = roundTrip(full) {
            assert("id", back.id == full.id)
            assert("name and path", back.name == full.name && back.path == full.path)
            assert("run number and attempt",
                   back.runNumber == full.runNumber && back.runAttempt == full.runAttempt)
            assert("branch and sha", back.headBranch == full.headBranch && back.headSHA == full.headSHA)
            assert("event", back.event == full.event)
            assert("both actors — they differ on a re-run, and the filter reads both",
                   back.actor?.login == "you" && back.triggeringActor?.login == "alice")
            assert("timestamps", back.runStartedAt == stamp && back.updatedAt == stamp)
            assert("html url", back.htmlURL == full.htmlURL)
        } else {
            print("  FAIL  a fully populated run did not survive the trip")
            failures += 1
        }

        print()
        print("── jobs and steps too, since the island draws those ──")
        let job = Job(
            id: 9_001,
            name: "terraform-apply",
            status: .inProgress,
            startedAt: stamp,
            completedAt: nil,
            htmlURL: "https://github.com/acme/web/actions/runs/42/job/9001",
            steps: [
                Step(name: "checkout", number: 1, status: .success, startedAt: stamp, completedAt: stamp),
                Step(name: "plan", number: 2, status: .inProgress, startedAt: stamp),
                Step(name: "apply", number: 3, status: .queued),
            ]
        )
        if let back = roundTrip(job) {
            assert("job id and name", back.id == job.id && back.name == job.name)
            check("job status", back.status, .inProgress)
            assert("all three steps came back", back.steps.count == 3)
            check("a settled step keeps its conclusion", back.steps.first?.status ?? .unknown, .success)
            check("a running step is still running", back.steps.dropFirst().first?.status ?? .unknown,
                  .inProgress)
            check("a queued step is still queued", back.steps.last?.status ?? .unknown, .queued)
            assert("step names and numbers", back.steps.map(\.name) == ["checkout", "plan", "apply"]
                       && back.steps.map(\.number) == [1, 2, 3])
            assert("a job still running has no completedAt", back.completedAt == nil)
            assert("job html url", back.htmlURL == job.htmlURL)
        } else {
            print("  FAIL  a job did not survive the trip")
            failures += 1
        }

        print()
        print("── and every status survives as a step ──")
        for status in RunStatus.allCases {
            guard let back = roundTrip(Step(name: "s", number: 1, status: status)) else {
                print("  FAIL  step \(status.rawValue) did not survive the trip at all")
                failures += 1
                continue
            }
            check("step \(status.rawValue)", back.status, expected(after: status))
        }

        print()
        if failures == 0 {
            print("RESULT: PASS — what the encoders write is what the decoders read")
        } else {
            print("RESULT: FAIL — \(failures) case(s) wrong")
            exit(1)
        }
    }
}
