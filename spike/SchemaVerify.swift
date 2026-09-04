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

    /// Set once GitHub has said the budget is spent. Every later request would
    /// get the same 403 and print the same line, which is noise and, more to
    /// the point, is the app's own rule: a refusal that will not change is not
    /// worth repeating.
    nonisolated(unsafe) static var budgetSpent = false

    /// A body, and only when GitHub actually sent one. A rate-limit response
    /// carries a JSON error that would otherwise be handed to the decoder and
    /// reported as a schema failure, which is the opposite of true.
    static func get(_ path: String) -> Data? {
        let outcome = probe(path)
        return outcome.status == 200 ? outcome.body : nil
    }

    /// `owner/repo (runs)` rather than the whole query string, which is noise
    /// in a skip line nobody asked to read.
    static func endpointName(_ path: String) -> String {
        let parts = path.split(separator: "/")
        guard parts.count >= 3 else { return path }
        let kind = path.contains("/jobs") ? "jobs" : "runs"
        return "\(parts[1])/\(parts[2]) (\(kind))"
    }

    /// Status, body and ETag, for the checks that care about the envelope
    /// rather than the payload.
    static func probe(_ path: String, ifNoneMatch: String? = nil)
        -> (status: Int, body: Data?, etag: String?, remaining: Int?) {
        guard let url = URL(string: "https://api.github.com" + path) else {
            return (0, nil, nil, nil)
        }
        guard !budgetSpent else { return (429, nil, nil, 0) }
        var request = URLRequest(url: url)
        if let ifNoneMatch { request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match") }
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
            var etag: String?
            var remaining: Int?
            var resetsAt: Double?
        }
        let result = Result()
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, _ in
            result.lock.lock()
            let http = response as? HTTPURLResponse
            result.status = http?.statusCode ?? 0
            result.payload = data
            result.etag = http?.value(forHTTPHeaderField: "ETag")
            result.remaining = http?.value(forHTTPHeaderField: "x-ratelimit-remaining").flatMap(Int.init)
            result.resetsAt = http?.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(Double.init)
            result.lock.unlock()
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 30)

        result.lock.lock()
        let outcome = (result.status, result.payload, result.etag, result.remaining)
        result.lock.unlock()

        if outcome.0 != 200 && outcome.0 != 304 {
            // Say which. "Rate limit or no network" sends people looking at
            // their wifi when the answer is a number GitHub already told us,
            // and the difference decides whether waiting helps.
            result.lock.lock()
            let remaining = result.remaining
            let resetsAt = result.resetsAt
            result.lock.unlock()
            if outcome.0 == 0 {
                print("  skip  \(endpointName(path)) -> no response (offline, or GitHub "
                      + "unreachable)")
            } else if let remaining, remaining == 0 {
                let minutes = resetsAt.map { max(0, Int(($0 - Date().timeIntervalSince1970) / 60)) }
                let when = minutes.map { "\($0) min" } ?? "shortly"
                print("  skip  \(endpointName(path)) -> HTTP \(outcome.0): the "
                      + "unauthenticated budget is spent (0 of 60), back in \(when). "
                      + "Nothing else will be asked.")
                budgetSpent = true
            } else {
                print("  skip  \(endpointName(path)) -> HTTP \(outcome.0)")
            }
        }
        return outcome
    }

    static func main() {
        var problems = 0
        var decoded = 0
        var dateShapes = Set<String>()
        var corpus: [WorkflowRun] = []
        // The first repository's response, kept so the payload-retention check
        // can ask a second question of it without paying for it twice. Sixty
        // requests an hour is the whole unauthenticated budget, and re-fetching
        // a body already in hand is exactly the waste this app exists to avoid.
        // The conditional-request check deliberately does not reuse it — see
        // the note there.
        var firstPath: String?
        var firstBody: Data?

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
            let path = "/repos/\(repository)/actions/runs?per_page=30&exclude_pull_requests=true"
            let outcome = probe(path)
            guard outcome.status == 200, let data = outcome.body else { continue }
            if firstBody == nil {
                firstPath = path
                firstBody = data
            }
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
        // Two is enough to exercise the jobs schema. Four costs two more
        // requests out of sixty for no coverage the first two did not give.
        for (repository, runID) in sampleRunIDs.prefix(2) {
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
        print("── invariants the views take for granted, on runs nobody wrote for a test ──")
        // Fixtures only ever contain the shapes somebody thought of. These are
        // the properties the island assumes without checking: `ForEach` needs
        // distinct identities, the progress ring needs a fraction, the elapsed
        // counter needs a non-negative duration, and the emit gate needs a
        // signature that exists.
        if corpus.isEmpty {
            print("  skip  no corpus to check")
        } else {
            let n = corpus.count
            func check(_ label: String, _ holds: Bool) {
                if holds { print("  ok    \(label)") }
                else { print("  FAIL  \(label)"); problems += 1 }
            }
            print("  \(n) runs from four repositories")
            // Identity carries the repository, which these all share per fetch,
            // so this is really "GitHub did not hand back the same run twice".
            check("no run id and attempt pair repeats within a repository",
                  Set(corpus.map { "\($0.id)/\($0.runAttempt)" }).count == n)
            check("progress is a fraction, never outside 0...1",
                  corpus.allSatisfy { (0.0...1.0).contains($0.progress) })
            check("no duration is negative — updated_at never precedes the start",
                  corpus.allSatisfy { ($0.duration ?? 0) >= 0 })
            check("every run produces a signature for the emit gate to compare",
                  corpus.allSatisfy { !$0.signature.isEmpty })
            check("a run is never both active and finished",
                  corpus.allSatisfy { !($0.isActive && $0.finishedAt != nil) })
            check("awaiting my approval always implies blocked on an approval",
                  corpus.allSatisfy { !$0.awaitsMyApproval || $0.isBlockedOnApproval })
            // Informational, and deliberately not an assertion: whether any
            // public repository happens to have a run sitting on a
            // first-time-contributor gate right now is not a property of this
            // app. It was two on one run of this and zero an hour later. When
            // it is above zero the approval path has been exercised by GitHub
            // rather than by a fixture, which is worth seeing; when it is zero
            // nothing is wrong.
            let blocked = corpus.filter(\.isBlockedOnApproval).count
            print("  note  \(blocked) of them are parked on a person"
                  + (blocked > 0
                     ? " — real `action_required` gates, which no fixture can supply"
                     : " right now; nothing is wrong, the corpus simply moved on"))
        }

        print()
        print("── how much of a payload this app actually keeps ──")
        // `ETagStore.memoise` releases the raw JSON once it has been decoded,
        // on the claim that the decoded value is far smaller. That is a claim
        // about GitHub's payloads, so it is worth re-measuring rather than
        // trusting: a run carries a whole `repository` object, a
        // `head_repository`, a `head_commit` and a wall of `*_url` links, and
        // Runway decodes none of them.
        if let data = firstBody,
           let payload = try? makeDecoder().decode(WorkflowRunsPayload.self, from: data) {
                // A floor on what the decoded runs cost: every string this app
                // keeps, plus a machine word for each of the fixed-width
                // fields. It cannot be exact from in here, but it is the right
                // order of magnitude and that is the whole point.
                var kept = 0
                for run in payload.workflowRuns {
                    kept += (run.name?.utf8.count ?? 0) + (run.path?.utf8.count ?? 0)
                    kept += (run.displayTitle?.utf8.count ?? 0) + (run.headBranch?.utf8.count ?? 0)
                    kept += (run.headSHA?.utf8.count ?? 0) + (run.event?.utf8.count ?? 0)
                    kept += (run.htmlURL?.utf8.count ?? 0) + run.repository.utf8.count
                    kept += run.logins.reduce(0) { $0 + $1.utf8.count }
                    kept += 8 * 6 // id, numbers, three dates, status
                }
                let share = Double(kept) / Double(data.count) * 100
                print(String(format: "  %d runs: %d KB on the wire, roughly %d KB kept (%.1f%%)",
                             payload.workflowRuns.count, data.count / 1024, kept / 1024, share))
                if share < 25 {
                    print("  ok    the decoded value is a small fraction of the body, which is "
                          + "what makes releasing the body worth doing")
                } else {
                    print("  note  the payload has slimmed down — ETagStore.memoise's note "
                          + "about proportions is out of date")
                }
        }

        print()
        print("── the conditional request the whole budget rests on ──")
        // `ETagStore` calls itself "the single most important piece of
        // rate-limit engineering in the app", and the reason is one documented
        // GitHub behaviour: a conditional request that answers 304 does not
        // count against the primary rate limit. Runway polls up to twenty
        // repositories every five seconds — 14,400 requests an hour against a
        // budget of 5,000 — and it only fits because almost none of them is
        // billed.
        //
        // If GitHub ever stopped issuing ETags here, or stopped honouring
        // If-None-Match, nothing would break. The app would keep working and
        // quietly burn twenty times the budget until it was throttled, which is
        // the kind of failure that gets diagnosed as "GitHub is flaky".
        if let path = firstPath {
            // Fetched again rather than reusing the body from the pass above,
            // and the reason is the budget note at the end of this block: it
            // subtracts one reading of `x-ratelimit-remaining` from another, so
            // the two have to be adjacent. Reusing the earlier response would
            // put eight other requests between them and report the 304 as
            // having cost nine.
            let first = probe(path)
            if let etag = first.etag {
                print("  ok    GitHub issues an ETag on the runs endpoint: \(etag.prefix(24))…")
                let second = probe(path, ifNoneMatch: etag)
                if second.status == 304 {
                    print("  ok    and answers 304 to If-None-Match, which is what makes the "
                          + "poll affordable")
                } else {
                    print("  FAIL  re-requesting with If-None-Match answered "
                          + "\(second.status), not 304 — the cache saves nothing and the "
                          + "budget arithmetic in docs/polling.md no longer holds")
                    problems += 1
                }
                // Unauthenticated, the exemption does not apply — GitHub is
                // explicit that it needs the Authorization header. Seeing the
                // budget move here is the evidence for why `GitHubClient.get`
                // throws `.noToken` rather than letting an empty token reach
                // the wire: without one, every 304 is billed.
                if let before = first.remaining, let after = second.remaining {
                    print("  note  unauthenticated, that 304 still cost \(before - after) "
                          + "request(s) — the exemption is authenticated-only, which is why "
                          + "an empty token must never reach the wire")
                }
            } else {
                print("  FAIL  no ETag on the runs endpoint — the conditional cache has "
                      + "nothing to send and every poll is billed in full")
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
            print(budgetSpent
                  ? "RESULT: SKIP — the unauthenticated budget is spent, so nothing was "
                    + "checked. This is not a failure; try again after the reset."
                  : "RESULT: SKIP — nothing came back to decode (GitHub unreachable)")
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
