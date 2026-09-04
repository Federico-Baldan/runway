// What does a poll do when GitHub misbehaves?
//
// The monitor's error handling is a set of deliberate, individually reasoned
// decisions — each one written down in a comment, none of them exercised. Job
// detail is a nicety, so a run whose jobs cannot be fetched still draws as a
// single line; a repository that 404s has been renamed or deleted, so it is
// demoted rather than treated as a failure; a body this client cannot read is
// reported in words rather than swallowed. All of those are claims about
// branches that only run when something is wrong, which is exactly when nobody
// is watching.
//
// Driven through an injected `URLProtocol` that can answer per endpoint, so
// each branch can be reached on demand with no network and no keychain.
//
//   swiftc -o /tmp/errpaths spike/ErrorPathVerify.swift \
//       Sources/Runway/Core/RunMonitor.swift Sources/Runway/API/GitHubClient.swift \
//       Sources/Runway/API/Models.swift Sources/Runway/API/Approvals.swift \
//       Sources/Runway/API/DeployTarget.swift Sources/Runway/API/RunScope.swift \
//       Sources/Runway/API/ETagStore.swift Sources/Runway/Auth/Keychain.swift \
//       && /tmp/errpaths

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A GitHub that can be told what to answer per endpoint.
final class FaultyGitHub: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var runsStatus = 200
    nonisolated(unsafe) static var runsBody = ""
    nonisolated(unsafe) static var jobsStatus = 200
    nonisolated(unsafe) static var jobsBody = #"{"total_count":0,"jobs":[]}"#

    static func set(runs: Int, runsBody rb: String, jobs: Int, jobsBody jb: String) {
        lock.lock(); runsStatus = runs; runsBody = rb; jobsStatus = jobs; jobsBody = jb; lock.unlock()
    }

    override class func canInit(with r: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.lock()
        let isJobs = path.hasSuffix("/jobs")
        let status = isJobs ? Self.jobsStatus : (path.hasSuffix("/actions/runs") ? Self.runsStatus : 200)
        let body = isJobs ? Self.jobsBody : (path.hasSuffix("/actions/runs") ? Self.runsBody : "{}")
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["x-ratelimit-limit": "5000", "x-ratelimit-remaining": "4900"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
enum ErrorPathVerify {
    static let liveRun = """
    {"total_count":1,"workflow_runs":[
     {"id":41,"name":"CI","run_number":7,"run_attempt":1,"status":"in_progress",
      "head_branch":"main","created_at":"2026-01-01T10:00:00Z",
      "updated_at":"2026-01-01T10:01:00Z","actor":{"login":"alice"},
      "triggering_actor":{"login":"alice"}}]}
    """

    static func monitor() -> RunMonitor {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FaultyGitHub.self]
        var cadence = RunMonitor.Cadence()
        cadence.idle = 3_600; cadence.active = 3_600
        return RunMonitor(client: GitHubClient(
            baseURL: URL(string: "https://api.github.com")!,
            session: URLSession(configuration: c),
            tokenProvider: { "ghp_x" }), cadence: cadence)
    }
    static func configure(_ m: RunMonitor) async {
        await m.configure(repoScope: .explicit, repoLimit: 10, organizations: [],
                          explicitRepositories: ["acme/api"], actorScope: .everyone,
                          watchedActors: [], approvalsFromOthers: false, currentUser: "alice")
    }

    static func main() async {
        var failures = 0
        func assert(_ l: String, _ c: Bool) {
            if c { print("  ok    \(l)") } else { print("  FAIL  \(l)"); failures += 1 }
        }

        print("── job detail is a nicety: a 404 on jobs must not lose the run ──")
        do {
            let m = monitor(); await configure(m)
            FaultyGitHub.set(runs: 200, runsBody: liveRun, jobs: 404, jobsBody: #"{"message":"Not Found"}"#)
            await m.refreshNow()
            let s = await m.currentState()
            assert("the run still reaches the island (got \(s.runs.count))", s.runs.count == 1)
            assert("with no job detail, which is what a single line needs",
                   s.runs.first?.jobs.isEmpty == true)
            assert("and no error is shown for it", s.error == nil)
        }

        print()
        print("── but a 500 on jobs is retryable, so the poll fails as a whole ──")
        do {
            let m = monitor(); await configure(m)
            FaultyGitHub.set(runs: 200, runsBody: liveRun, jobs: 500, jobsBody: "{}")
            await m.refreshNow()
            let s = await m.currentState()
            assert("an error is surfaced", s.error != nil)
            assert("and nothing half-written reached the island (got \(s.runs.count))",
                   s.runs.isEmpty)
        }

        print()
        print("── a body this client cannot read ──")
        do {
            let m = monitor(); await configure(m)
            FaultyGitHub.set(runs: 200, runsBody: "{ not json at all", jobs: 200, jobsBody: "{}")
            await m.refreshNow()
            let s = await m.currentState()
            assert("the decode failure is reported rather than swallowed", s.error != nil)
            assert("and it says so in words a person can act on",
                   s.error?.contains("read GitHub") == true)
        }

        print()
        print("── an empty page is not an error ──")
        do {
            let m = monitor(); await configure(m)
            FaultyGitHub.set(runs: 200, runsBody: #"{"total_count":0,"workflow_runs":[]}"#,
                             jobs: 200, jobsBody: "{}")
            await m.refreshNow()
            let s = await m.currentState()
            assert("no runs, no complaint", s.runs.isEmpty && s.error == nil)
            assert("the repository is still being watched",
                   s.repositories == ["acme/api"])
        }

        print()
        print("── a repository that 404s is demoted, not fatal ──")
        do {
            let m = monitor(); await configure(m)
            FaultyGitHub.set(runs: 404, runsBody: #"{"message":"Not Found"}"#, jobs: 200, jobsBody: "{}")
            await m.refreshNow()
            let s = await m.currentState()
            assert("no error — a renamed or deleted repo is not a failure", s.error == nil)
            assert("and no runs", s.runs.isEmpty)
        }

        print()
        print(failures == 0 ? "RESULT: PASS — the poll degrades the way its comments claim"
                            : "RESULT: FAIL — \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
