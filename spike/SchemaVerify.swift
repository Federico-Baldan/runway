// Does GitHub still send what these decoders expect — today, not in 2026?
//
// The decoding contract is the one part of this app that can rot without
// anybody touching it. A renamed field turns every run into a silent
// `.unknown`; a status pair nobody has seen before does the same to one row; a
// timestamp in an unfamiliar shape throws `.decoding`, which fails the whole
// poll. None of that is visible from inside the repository, because every
// fixture in `spike/` was written from the schema as it was understood on the
// day it was written.
//
// `RunsSpike` asks the same question and needs a token in the keychain to do
// it, so it cannot run in CI and only ever sees whatever repositories that one
// token can reach. This asks it **unauthenticated**, against public
// repositories, so anybody — or any machine — can run it. Sixty requests an
// hour per IP is plenty for five.
//
// Rate limiting and a missing network are a SKIP, not a failure: a check that
// goes red because GitHub is busy teaches people to ignore it. Only a payload
// that arrived and did not decode is a problem.
//
//   swiftc -o /tmp/schemaverify spike/SchemaVerify.swift \
//       Sources/Runway/API/GitHubClient.swift Sources/Runway/API/Models.swift \
//       Sources/Runway/API/Approvals.swift Sources/Runway/API/DeployTarget.swift \
//       Sources/Runway/API/RunScope.swift Sources/Runway/API/ETagStore.swift \
//       Sources/Runway/Auth/Keychain.swift && /tmp/schemaverify

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@main
enum SchemaVerify {
    /// Public repositories that run a lot of Actions, so there is always
    /// something recent to decode — and none of which deploys anywhere through
    /// these public workflows, which is what makes them useful twice. See the
    /// classifier section in `main`.
    static let repositories = [
        "Homebrew/brew", "swiftlang/swift", "vercel/next.js", "grafana/grafana",
    ]

    /// The decoder `GitHubClient` builds, reproduced exactly — including the
    /// date strategy, which is the half that throws rather than degrades.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = GitHubDate.parse(raw) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Unrecognized date format: \(raw)")
            )
        }
        return decoder
    }

    /// One session for the process, not one per request. Creating and
    /// dropping a session per call trips a deinit bug in
    /// swift-corelibs-foundation, and it is the wrong shape regardless: a
    /// session owns a connection pool worth reusing across five requests.
    static let session = URLSession(configuration: .ephemeral)

    static func get(_ path: String) -> Data? {
        guard let url = URL(string: "https://api.github.com" + path) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // The version the app pins. If GitHub ever retires it, this is where
        // that shows up first.
        request.setValue(GitHubClient.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Runway", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        // A box rather than captured vars: the completion handler runs on
        // URLSession's own queue, and Swift 6 will not let a closure crossing
        // that boundary write to the caller's locals.
        final class Result: @unchecked Sendable {
            let lock = NSLock()
            var payload: Data?
            var status = 0
        }
        let result = Result()
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, _ in
            result.lock.lock()
            result.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            result.payload = data
            result.lock.unlock()
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 30)

        result.lock.lock()
        let status = result.status
        let payload = result.payload
        result.lock.unlock()

        guard status == 200 else {
            print("  skip  \(path) -> HTTP \(status) (rate limit or no network)")
            return nil
        }
        return payload
    }

    static func main() {
        var problems = 0
        var decoded = 0
        var dateShapes = Set<String>()
        var corpus: [WorkflowRun] = []

        /// Every ISO-looking string in the payload, with its digits masked, so
        /// the *shapes* GitHub sends are visible rather than the values.
        func collectDateShapes(_ data: Data) {
            guard let text = String(data: data, encoding: .utf8) else { return }
            for match in text.split(separator: "\"") where match.count == 20 || match.count == 24 {
                guard match.hasSuffix("Z"), match.contains("T"),
                      match.prefix(4).allSatisfy(\.isNumber) else { continue }
                dateShapes.insert(String(match.map { $0.isNumber ? "N" : $0 }))
            }
        }

        print("── workflow runs, decoded by the real types ──")
        var sampleRunIDs: [(String, Int)] = []
        for repository in repositories {
            guard let data = get(
                "/repos/\(repository)/actions/runs?per_page=30&exclude_pull_requests=true"
            ) else { continue }
            collectDateShapes(data)
            do {
                let payload = try makeDecoder().decode(WorkflowRunsPayload.self, from: data)
                decoded += 1
                print("  ok    \(repository): \(payload.workflowRuns.count) runs decoded")

                let unknown = payload.workflowRuns.filter { $0.status == .unknown }
                if unknown.isEmpty {
                    print("  ok    every status/conclusion pair was recognised")
                } else {
                    print("  FAIL  \(unknown.count) run(s) fused to .unknown — GitHub has a "
                          + "status or conclusion this build does not know")
                    problems += 1
                }
                // `startedAt` is what every elapsed counter measures from.
                if payload.workflowRuns.allSatisfy({ $0.startedAt != nil }) {
                    print("  ok    every run has a start time to count from")
                } else {
                    print("  FAIL  a run arrived with neither created_at nor run_started_at")
                    problems += 1
                }
                if let first = payload.workflowRuns.first {
                    sampleRunIDs.append((repository, first.id))
                }
                corpus.append(contentsOf: payload.workflowRuns)
            } catch {
                print("  FAIL  \(repository) did not decode: \(error)")
                problems += 1
            }
        }

        print()
        print("── jobs and steps, which is the deeper half of the schema ──")
        for (repository, runID) in sampleRunIDs {
            guard let data = get(
                "/repos/\(repository)/actions/runs/\(runID)/jobs?filter=latest&per_page=50"
            ) else { continue }
            collectDateShapes(data)
            do {
                let payload = try makeDecoder().decode(JobsPayload.self, from: data)
                decoded += 1
                let steps = payload.jobs.reduce(0) { $0 + $1.steps.count }
                print("  ok    \(repository) #\(runID): \(payload.jobs.count) jobs, \(steps) steps")

                let unknownJobs = payload.jobs.filter { $0.status == .unknown }.count
                let unknownSteps = payload.jobs.flatMap(\.steps).filter { $0.status == .unknown }.count
                if unknownJobs == 0 && unknownSteps == 0 {
                    print("  ok    every job and step status was recognised")
                } else {
                    print("  FAIL  \(unknownJobs) job / \(unknownSteps) step status(es) fused to .unknown")
                    problems += 1
                }
            } catch {
                print("  FAIL  \(repository) #\(runID) jobs did not decode: \(error)")
                problems += 1
            }
        }

        print()
        print("── what the deploy classifier makes of real workflow names ──")
        // The classifier guesses an environment from names people chose, and
        // its worst failure is being loud: `DeployClassifier` says outright
        // that "this is going to production" is a sentence a status app had
        // better not be casually wrong about. Fixtures cannot catch a
        // vocabulary that has drifted too broad — only names nobody wrote for
        // this test can.
        //
        // None of the repositories above deploys through these public
        // workflows, so a production label on any of them means a word has been
        // added that is far too common. `canary` is the standing example of the
        // trap: it is a real deployment term and it is also next.js's default
        // branch, so admitting it would put a deploy chip on every run in that
        // repository.
        var labels: [String] = []
        var production = 0
        for run in corpus {
            guard let target = run.stampingDeployTarget().deployTarget else { continue }
            labels.append("[\(target.tier)] \(target.name) via .\(target.source) — \(run.name ?? "?")")
            if target.tier == .production { production += 1 }
        }
        if corpus.isEmpty {
            print("  skip  no runs to classify")
        } else {
            print("  \(labels.count) of \(corpus.count) runs were given a deploy label")
            for label in Set(labels).sorted().prefix(8) { print("    \(label)") }
            if production == 0 {
                print("  ok    nothing in a corpus of ordinary CI was called production")
            } else {
                print("  FAIL  \(production) run(s) labelled production — the vocabulary has "
                      + "drifted broad enough to be wrong about the one thing that matters")
                problems += 1
            }
        }

        print()
        print("── the timestamp shapes GitHub actually sends ──")
        // `GitHubDate.parse` tries whole seconds first on the claim that this is
        // the only shape these endpoints use. Worth seeing rather than assuming:
        // anything else here means the fallback path is load-bearing, not spare.
        for shape in dateShapes.sorted() { print("  \(shape)") }
        if dateShapes == ["NNNN-NN-NNTNN:NN:NNZ"] {
            print("  ok    whole seconds only, which is the order parse() tries first")
        } else if !dateShapes.isEmpty {
            print("  note  more than one shape is in play — see GitHubDate.parse")
        }

        print()
        if decoded == 0 {
            print("RESULT: SKIP — nothing came back to decode (rate limit or no network)")
            exit(0)
        }
        if problems == 0 {
            print("RESULT: PASS — the decoding contract still matches what GitHub sends today")
        } else {
            print("RESULT: FAIL — \(problems) problem(s) against live data")
            exit(1)
        }
    }
}
