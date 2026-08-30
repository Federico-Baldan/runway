// What does a real workflow run decode to?
//
// The decoding contract is the part most likely to rot: GitHub adds fields, and
// a rename of one Runway reads turns every run into a silent `.unknown`. This
// walks real repositories and prints what came back, flagging anything that
// decoded to nothing.
//
//   swiftc -o /tmp/runsspike spike/RunsSpike.swift \
//       Sources/Runway/API/GitHubClient.swift Sources/Runway/API/Models.swift \
//       Sources/Runway/API/RunScope.swift Sources/Runway/API/ETagStore.swift \
//       Sources/Runway/Auth/Keychain.swift && /tmp/runsspike

import Foundation

@main
enum RunsSpike {
    static func main() {
        guard TokenCache.shared.token() != nil else {
            print("no token in the keychain. Run: AuthSpike store <TOKEN>")
            exit(1)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var problems: [String] = []

        Task {
            let client = GitHubClient()
            do {
                let user = try await client.fetchAuthenticatedUser()
                let repositories = try await client.fetchRepositories(
                    scope: .recent, limit: 8, organizations: [], explicit: []
                )

                var seenStatuses = Set<String>()
                var seenEvents = Set<String>()
                var seenLogins = Set<String>()
                var totalRuns = 0

                for repository in repositories {
                    let response = try await client.fetchRuns(repository: repository.fullName, perPage: 5)
                    let runs = response.value.workflowRuns
                    guard !runs.isEmpty else { continue }
                    totalRuns += runs.count

                    print("── \(repository.fullName) — \(response.value.totalCount) runs ──")
                    for run in runs {
                        seenStatuses.insert(run.status.rawValue)
                        if let event = run.event { seenEvents.insert(event) }
                        seenLogins.formUnion(run.logins)

                        let elapsed = run.duration.map { String(format: "%.0fs", $0) } ?? "—"
                        let who = run.triggeringActor?.login ?? run.actor?.login ?? "?"
                        print("  #\(run.runNumber) \(run.title)  [\(run.status.rawValue)]"
                            + "  \(run.headBranch ?? "?")  by \(who)  \(elapsed)"
                            + (run.isRerun ? "  (attempt \(run.runAttempt))" : ""))

                        // Every one of these decoding to nothing means a field moved.
                        if run.status == .unknown { problems.append("#\(run.runNumber): status decoded to .unknown") }
                        if run.startedAt == nil { problems.append("#\(run.runNumber): no start time") }
                        if run.webURL() == nil { problems.append("#\(run.runNumber): no web URL") }
                        if run.logins.isEmpty { problems.append("#\(run.runNumber): no actor at all") }
                        if !run.isActive, run.duration == nil {
                            problems.append("#\(run.runNumber): finished but no duration")
                        }

                        // Job detail, for the run most worth drawing.
                        if run.isActive || run.runNumber == runs.first?.runNumber {
                            let jobs = try await client.fetchJobs(
                                repository: repository.fullName, runID: run.id
                            ).value
                            for job in jobs {
                                let steps = job.steps.map { "\($0.name)=\($0.status.rawValue)" }
                                print("      \(job.name) [\(job.status.rawValue)]  \(steps.joined(separator: " "))")
                                if job.status == .unknown {
                                    problems.append("job \(job.name): status decoded to .unknown")
                                }
                            }
                            if jobs.isEmpty, run.isActive {
                                print("      (no jobs yet — waiting for a runner)")
                            }
                        }
                    }
                    print()
                }

                print("── summary ──")
                print("signed in as       \(user.login)")
                print("repositories       \(repositories.count)")
                print("runs decoded       \(totalRuns)")
                print("statuses seen      \(seenStatuses.sorted().joined(separator: ", "))")
                print("events seen        \(seenEvents.sorted().joined(separator: ", "))")
                print("actors seen        \(seenLogins.sorted().joined(separator: ", "))")

                let rate = await client.currentRateLimit()
                print("rate limit         \(rate.remaining)/\(rate.limit), \(rate.savedRequests) free")

                if totalRuns == 0 {
                    problems.append("no runs found anywhere — cannot confirm the decoding contract")
                }
            } catch {
                problems.append((error as? GitHubError)?.errorDescription ?? error.localizedDescription)
            }
            semaphore.signal()
        }

        semaphore.wait()
        print()
        if problems.isEmpty {
            print("RESULT: PASS — every run decoded with a status, a start, a URL and an actor")
        } else {
            print("RESULT: FAIL")
            for problem in problems.prefix(20) { print("  \(problem)") }
            exit(1)
        }
    }
}
