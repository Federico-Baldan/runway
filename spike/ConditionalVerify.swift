// Does the conditional cache hand back the right value on a 304?
//
// `ETagStore` is the machinery the whole poll budget rests on, and the half of
// it that cannot be checked by inspection is what happens across an actual
// round trip: the store keeps a body, `memoise` releases it once decoded, and
// from then on a 304 can only be answered from the remembered value. If that
// remembering is wrong the island does not error — it quietly serves nothing,
// or last week's runs, for as long as the entry survives.
//
// `RateBudgetVerify` checks the store's own arithmetic. This drives the real
// `GitHubClient` against a scripted GitHub through an injected `URLProtocol`,
// so the 200, the `If-None-Match`, the 304 and the rate-limit accounting all
// happen for real. No network, no token, no keychain.
//
//   swiftc -o /tmp/condverify spike/ConditionalVerify.swift \
//       Sources/Runway/API/GitHubClient.swift Sources/Runway/API/Models.swift \
//       Sources/Runway/API/Approvals.swift Sources/Runway/API/DeployTarget.swift \
//       Sources/Runway/API/RunScope.swift Sources/Runway/API/ETagStore.swift \
//       Sources/Runway/Auth/Keychain.swift && /tmp/condverify

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A GitHub that answers from a script, so the conditional-request machinery
/// can be driven end to end without a network or a token.
final class ScriptedGitHub: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var requests: [(path: String, ifNoneMatch: String?)] = []
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var etag = "W/\"v1\""

    /// Plain synchronous methods: `NSLock.lock()` cannot be called from an
    /// async context, and every caller below is inside one.
    static func serve(_ newBody: Data, etag newETag: String) {
        lock.lock(); body = newBody; etag = newETag; lock.unlock()
    }
    static func reset(_ newBody: Data, etag newETag: String) {
        lock.lock(); requests = []; body = newBody; etag = newETag; lock.unlock()
    }
    static var log: [(path: String, ifNoneMatch: String?)] {
        lock.lock(); defer { lock.unlock() }; return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append((request.url?.path ?? "?",
                              request.value(forHTTPHeaderField: "If-None-Match")))
        let currentETag = Self.etag
        let payload = Self.body
        Self.lock.unlock()

        // The behaviour confirmed against real GitHub in SchemaVerify: a
        // matching validator gets a 304 with no body at all.
        let notModified = request.value(forHTTPHeaderField: "If-None-Match") == currentETag
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: notModified ? 304 : 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "ETag": currentETag,
                "x-ratelimit-limit": "5000",
                "x-ratelimit-remaining": notModified ? "4999" : "4998",
            ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !notModified { client?.urlProtocol(self, didLoad: payload) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
enum ConditionalVerify {
    static let runsJSON = """
    {"total_count":2,"workflow_runs":[
     {"id":41,"name":"CI","run_number":7,"run_attempt":1,"status":"in_progress",
      "head_branch":"main","created_at":"2026-01-01T10:00:00Z",
      "updated_at":"2026-01-01T10:01:00Z",
      "actor":{"login":"alice"},"triggering_actor":{"login":"alice"}},
     {"id":42,"name":"Deploy","run_number":8,"run_attempt":1,"status":"completed",
      "conclusion":"success","head_branch":"main","created_at":"2026-01-01T09:00:00Z",
      "updated_at":"2026-01-01T09:05:00Z","actor":{"login":"bob"},
      "triggering_actor":{"login":"bob"}}]}
    """

    // `async main`, not a Task plus a semaphore. Blocking the main thread on a
    // DispatchSemaphore starves the cooperative pool the Task needs, so the
    // body never runs — and a harness whose assertions never execute reports a
    // clean pass having checked nothing. That is exactly what the first draft
    // of this file did, for thirty seconds, before the timing gave it away.
    static func main() async {
        var failures = 0
        func assert(_ label: String, _ condition: Bool) {
            if condition { print("  ok    \(label)") }
            else { print("  FAIL  \(label)"); failures += 1 }
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedGitHub.self]
        let client = GitHubClient(
            baseURL: URL(string: "https://api.github.com")!,
            session: URLSession(configuration: config),
            tokenProvider: { "ghp_scripted" })

        ScriptedGitHub.reset(Data(runsJSON.utf8), etag: "W/\"v1\"")

        do {
            print("── a 200, then a 304 for the same resource ──")
            let first = try await client.fetchRuns(repository: "acme/api", perPage: 30)
            assert("the first response is a 200, decoded", !first.notModified)
            assert("and carries both runs", first.value.workflowRuns.count == 2)
            assert("no If-None-Match went out — nothing was cached yet",
                   ScriptedGitHub.log.first?.ifNoneMatch == nil)

            let second = try await client.fetchRuns(repository: "acme/api", perPage: 30)
            assert("the second request sent the ETag it was given",
                   ScriptedGitHub.log.last?.ifNoneMatch == "W/\"v1\"")
            assert("and GitHub answered 304", second.notModified)
            // The memo doing its job. `store` keeps the body, `memoise`
            // releases it, so a 304 can only be answered from the remembered
            // value — if that were wrong this would be empty or throw.
            assert("the 304 still yields both runs, out of the decode memo",
                   second.value.workflowRuns.count == 2)
            assert("identical content, not a re-parse that drifted",
                   second.value.workflowRuns.map(\.identity)
                       == first.value.workflowRuns.map(\.identity))
            let rate = await client.currentRateLimit()
            assert("the rate limit counts it as saved rather than billed",
                   rate.savedRequests == 1 && rate.billedRequests == 1)
            assert("exactly two requests reached the wire", ScriptedGitHub.log.count == 2)

            print()
            print("── the resource changes underneath ──")
            // A new validator has to invalidate the memo, or the island
            // freezes on a stale answer for as long as the entry survives.
            ScriptedGitHub.serve(
                Data(runsJSON.replacingOccurrences(of: "\"id\":41", with: "\"id\":99").utf8),
                etag: "W/\"v2\"")

            let third = try await client.fetchRuns(repository: "acme/api", perPage: 30)
            assert("a changed resource answers 200 again", !third.notModified)
            assert("and the new content replaces the memo",
                   third.value.workflowRuns.contains { $0.id == 99 })
            assert("the stale run is gone",
                   !third.value.workflowRuns.contains { $0.id == 41 })

            let fourth = try await client.fetchRuns(repository: "acme/api", perPage: 30)
            assert("the next conditional request sends the NEW validator",
                   ScriptedGitHub.log.last?.ifNoneMatch == "W/\"v2\"")
            assert("and resolves to the new content, not the old memo",
                   fourth.value.workflowRuns.contains { $0.id == 99 })
        } catch {
            print("  FAIL  threw: \(error)")
            failures += 1
        }

        print()
        print(failures == 0
              ? "RESULT: PASS — the conditional cache serves the right value on a real 304"
              : "RESULT: FAIL — \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
