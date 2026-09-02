import Foundation
import SwiftUI

/// Scripted workflow runs that play out locally.
///
/// Exists because a real Actions run takes a minute or two and burns CI
/// minutes, so every visual state would otherwise be several minutes apart.
/// The demo loops a passing run, a failing run and three concurrent runs by
/// two different people, so any state is a few seconds away — including the
/// multi-actor labelling, which is otherwise awkward to reproduce alone.
@MainActor
public enum DemoData {
    /// One frame of a scripted run.
    struct Frame {
        let at: TimeInterval
        let runStatus: RunStatus
        /// job name -> status
        let jobs: [(String, RunStatus)]
        /// step name -> (job, status)
        let steps: [(String, String, RunStatus)]
        /// Environments the run is parked on, if any.
        var pending: [PendingDeployment] = []
    }

    /// The environment a demo deploy waits on, with this account on the
    /// reviewer list — the shape `ApprovalCheck` reads as `.needsMe`.
    nonisolated static func production(canApprove: Bool) -> PendingDeployment {
        PendingDeployment(
            environment: PendingDeployment.Environment(id: 4_211, name: "production"),
            waitTimer: 0,
            waitTimerStartedAt: nil,
            currentUserCanApprove: canApprove,
            reviewers: canApprove
                ? [DeploymentReviewer(kind: .user, name: "you"),
                   DeploymentReviewer(kind: .team, name: "platform")]
                : [DeploymentReviewer(kind: .user, name: "alice")]
        )
    }

    /// A compressed but faithful build-and-deploy run.
    static let script: [Frame] = [
        Frame(at: 0, runStatus: .queued,
              jobs: [("test", .queued), ("deploy", .queued)],
              steps: [("checkout", "test", .queued), ("unit", "test", .queued),
                      ("integration", "test", .queued), ("deploy to staging", "deploy", .queued)]),

        Frame(at: 2, runStatus: .inProgress,
              jobs: [("test", .inProgress), ("deploy", .queued)],
              steps: [("checkout", "test", .success), ("unit", "test", .inProgress),
                      ("integration", "test", .queued), ("deploy to staging", "deploy", .queued)]),

        Frame(at: 7, runStatus: .inProgress,
              jobs: [("test", .inProgress), ("deploy", .queued)],
              steps: [("checkout", "test", .success), ("unit", "test", .success),
                      ("integration", "test", .inProgress), ("deploy to staging", "deploy", .queued)]),

        Frame(at: 13, runStatus: .inProgress,
              jobs: [("test", .success), ("deploy", .inProgress)],
              steps: [("checkout", "test", .success), ("unit", "test", .success),
                      ("integration", "test", .success), ("deploy to staging", "deploy", .inProgress)]),

        Frame(at: 20, runStatus: .success,
              jobs: [("test", .success), ("deploy", .success)],
              steps: [("checkout", "test", .success), ("unit", "test", .success),
                      ("integration", "test", .success), ("deploy to staging", "deploy", .success)]),
    ]

    /// A second, failing run so the red path gets exercised too.
    static let failScript: [Frame] = [
        Frame(at: 0, runStatus: .inProgress,
              jobs: [("lint", .inProgress), ("test", .queued)],
              steps: [("eslint", "lint", .inProgress), ("unit", "test", .queued)]),

        Frame(at: 5, runStatus: .inProgress,
              jobs: [("lint", .inProgress), ("test", .queued)],
              steps: [("eslint", "lint", .inProgress), ("unit", "test", .queued)]),

        Frame(at: 9, runStatus: .failure,
              jobs: [("lint", .failure), ("test", .skipped)],
              steps: [("eslint", "lint", .failure), ("unit", "test", .skipped)]),
    ]

    /// A run that reaches its deploy stage and stops, waiting for a person.
    ///
    /// The state the whole approval feature exists for, and the one that is
    /// otherwise almost impossible to see while developing: it needs a
    /// repository with a protected environment, a deploy job, and somebody
    /// willing to leave it hanging.
    static let approvalScript: [Frame] = [
        Frame(at: 0, runStatus: .inProgress,
              jobs: [("build", .inProgress), ("deploy", .queued)],
              steps: [("compile", "build", .inProgress), ("bundle", "build", .queued),
                      ("release", "deploy", .queued)]),

        Frame(at: 4, runStatus: .inProgress,
              jobs: [("build", .success), ("deploy", .waiting)],
              steps: [("compile", "build", .success), ("bundle", "build", .success),
                      ("release", "deploy", .waiting)],
              pending: [production(canApprove: true)]),

        Frame(at: 9, runStatus: .waiting,
              jobs: [("build", .success), ("deploy", .waiting)],
              steps: [("compile", "build", .success), ("bundle", "build", .success),
                      ("release", "deploy", .waiting)],
              pending: [production(canApprove: true)]),

        Frame(at: 15, runStatus: .inProgress,
              jobs: [("build", .success), ("deploy", .inProgress)],
              steps: [("compile", "build", .success), ("bundle", "build", .success),
                      ("release", "deploy", .inProgress)]),

        Frame(at: 20, runStatus: .success,
              jobs: [("build", .success), ("deploy", .success)],
              steps: [("compile", "build", .success), ("bundle", "build", .success),
                      ("release", "deploy", .success)]),
    ]

    /// Build one run from a script frame.
    static func run(
        frame: Frame,
        repository: String,
        id: Int,
        runNumber: Int,
        branch: String,
        login: String,
        startedAt: Date,
        attempt: Int = 1
    ) -> WorkflowRun {
        let stepsByJob = Dictionary(grouping: frame.steps, by: { $0.1 })
        let jobs = frame.jobs.enumerated().map { index, entry -> Job in
            let (name, status) = entry
            let steps = (stepsByJob[name] ?? []).enumerated().map { stepIndex, step in
                Step(name: step.0, number: stepIndex + 1, status: step.2)
            }
            return Job(
                id: id * 100 + index,
                name: name,
                status: status,
                startedAt: startedAt,
                completedAt: status.isTerminal ? Date() : nil,
                steps: steps
            )
        }

        return WorkflowRun(
            id: id,
            name: "build",
            path: ".github/workflows/build.yml",
            displayTitle: "Update \(branch)",
            runNumber: runNumber,
            runAttempt: attempt,
            headBranch: branch,
            headSHA: String(format: "%040x", id),
            event: attempt > 1 ? "workflow_dispatch" : "push",
            status: frame.runStatus,
            htmlURL: "https://github.com/\(repository)/actions/runs/\(id)",
            createdAt: startedAt,
            updatedAt: Date(),
            runStartedAt: startedAt,
            actor: GitHubActor(login: login),
            triggeringActor: GitHubActor(login: login),
            repository: repository,
            jobs: jobs,
            pendingDeployments: frame.pending
        )
        // What `RunMonitor` does to every real run once its detail has landed.
        // Without it the demo is the one place the island draws runs with no
        // environment on them, which is the state hardest to notice is missing.
        .stampingDeployTarget()
    }

    /// A state with one run in it.
    static func state(
        frame: Frame,
        repository: String,
        id: Int,
        runNumber: Int,
        branch: String,
        login: String,
        startedAt: Date
    ) -> MonitorState {
        MonitorState(
            runs: [run(frame: frame, repository: repository, id: id, runNumber: runNumber,
                       branch: branch, login: login, startedAt: startedAt)],
            repositories: [repository],
            lastUpdate: Date(),
            isPolling: true,
            rateLimit: RateLimit(limit: 5000, remaining: 4837, resetsAt: Date().addingTimeInterval(2400),
                                 billedRequests: 163, savedRequests: 1_204),
            knownActors: [login]
        )
    }

    /// Three runs at once, by two different people — the multi-actor layout.
    public static func concurrentState(tick: Int, withFailure: Bool = false) -> MonitorState {
        let now = Date()
        let runs = [
            run(frame: script[min(tick + 1, script.count - 1)],
                repository: "acme/web-app", id: 90_100, runNumber: 562,
                branch: "main", login: "you", startedAt: now.addingTimeInterval(-84)),
            run(frame: withFailure ? failScript[2] : script[min(tick, script.count - 1)],
                repository: "acme/api", id: 90_200, runNumber: 1_204,
                branch: "feat/payments", login: "alice", startedAt: now.addingTimeInterval(-41)),
            run(frame: approvalScript[min(tick + 1, approvalScript.count - 1)],
                repository: "acme/infra", id: 90_300, runNumber: 88,
                branch: "release/2.4", login: "bob", startedAt: now.addingTimeInterval(-12),
                attempt: 2),
        ]
        return MonitorState(
            runs: runs,
            repositories: ["acme/web-app", "acme/api", "acme/infra"],
            lastUpdate: now,
            isPolling: true,
            rateLimit: RateLimit(limit: 5000, remaining: 4837, resetsAt: now.addingTimeInterval(2400),
                                 billedRequests: 163, savedRequests: 1_204),
            knownActors: ["alice", "bob", "you"]
        )
    }

    /// Loop the scripts forever: success run, gap, failing run, gap, three at once.
    public static func run(model: IslandModel) -> Task<Void, Never> {
        Task { @MainActor in
            var cycle = 0
            while !Task.isCancelled {
                let startedAt = Date()
                switch cycle % 4 {
                case 0:
                    for frame in script {
                        guard !Task.isCancelled else { return }
                        model.apply(state(frame: frame, repository: "acme/web-app",
                                          id: 90_100 + cycle, runNumber: 562 + cycle,
                                          branch: "main", login: "you", startedAt: startedAt))
                        try? await Task.sleep(nanoseconds: 2_400_000_000)
                    }
                case 1:
                    for frame in approvalScript {
                        guard !Task.isCancelled else { return }
                        model.apply(state(frame: frame, repository: "acme/infra",
                                          id: 90_300 + cycle, runNumber: 88 + cycle,
                                          branch: "release/2.4", login: "you",
                                          startedAt: startedAt))
                        try? await Task.sleep(nanoseconds: 2_600_000_000)
                    }
                case 2:
                    for frame in failScript {
                        guard !Task.isCancelled else { return }
                        model.apply(state(frame: frame, repository: "acme/api",
                                          id: 90_200 + cycle, runNumber: 1_204 + cycle,
                                          branch: "feat/payments", login: "alice",
                                          startedAt: startedAt))
                        try? await Task.sleep(nanoseconds: 2_600_000_000)
                    }
                default:
                    for tick in 0..<script.count {
                        guard !Task.isCancelled else { return }
                        model.apply(concurrentState(tick: tick))
                        try? await Task.sleep(nanoseconds: 2_200_000_000)
                    }
                }

                // Let the island settle and leave before the next cycle.
                model.apply(MonitorState(lastUpdate: Date(), isPolling: true))
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                cycle += 1
            }
        }
    }
}
