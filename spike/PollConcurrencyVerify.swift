// Can two polls run at once, and is a refusal to start one ever silently lost?
//
// `pollOnce` is awaits nearly all the way down, and an actor serialises
// statements rather than calls — so every one of those awaits is a point where
// a second caller gets to start. Four things call in besides the loop: Refresh
// Now, waking from sleep, changing the host, changing the token. Three of them
// fire alongside something that was already going to poll.
//
// The guard against that has two halves, and they pull in opposite directions.
// `isPollInFlight` makes a second call stand down, which is right when the
// flight in progress will produce the answer. `pendingRefresh` records that it
// stood down, because three of those four callers have just invalidated
// everything — so the poll being coalesced onto is about to discard its own
// results, and dropping the refresh leaves nothing to write the new answer.
//
// Both halves are invisible from outside: too many polls looks like GitHub
// being slow, and a dropped refresh looks like the app ignoring you. Neither
// can be seen without driving the real actor, which is what this does — through
// an injected `URLProtocol`, with no network and no keychain.
//
//   swiftc -o /tmp/pollconc spike/PollConcurrencyVerify.swift \
//       Sources/Runway/Core/RunMonitor.swift Sources/Runway/API/GitHubClient.swift \
//       Sources/Runway/API/Models.swift Sources/Runway/API/Approvals.swift \
//       Sources/Runway/API/DeployTarget.swift Sources/Runway/API/RunScope.swift \
//       Sources/Runway/API/ETagStore.swift Sources/Runway/Auth/Keychain.swift \
//       && /tmp/pollconc

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A GitHub that can be held open, so a poll can be caught mid-flight.
final class SlowGitHub: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var runsRequests = 0
    nonisolated(unsafe) static var delay: TimeInterval = 0

    static func reset(delay newDelay: TimeInterval) {
        lock.lock(); runsRequests = 0; delay = newDelay; lock.unlock()
    }
    static var runsCount: Int {
        lock.lock(); defer { lock.unlock() }; return runsRequests
    }

    static let runsJSON = """
    {"total_count":1,"workflow_runs":[
     {"id":41,"name":"CI","run_number":7,"run_attempt":1,"status":"completed",
      "conclusion":"success","head_branch":"main",
      "created_at":"2026-01-01T10:00:00Z","updated_at":"2026-01-01T10:01:00Z",
      "actor":{"login":"alice"},"triggering_actor":{"login":"alice"}}]}
    """

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.lock()
        if path.hasSuffix("/actions/runs") { Self.runsRequests += 1 }
        let hold = Self.delay
        Self.lock.unlock()

        // A run list for the runs endpoint, an empty object for anything else
        // the poll happens to reach.
        let body = path.hasSuffix("/actions/runs")
            ? Data(Self.runsJSON.utf8)
            : Data("{}".utf8)

        if hold > 0 { Thread.sleep(forTimeInterval: hold) }

        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["x-ratelimit-limit": "5000", "x-ratelimit-remaining": "4900"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
enum PollConcurrencyVerify {
    static func makeMonitor() -> RunMonitor {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SlowGitHub.self]
        let client = GitHubClient(
            baseURL: URL(string: "https://api.github.com")!,
            session: URLSession(configuration: config),
            tokenProvider: { "ghp_scripted" })
        // A cadence that polls once and then goes quiet, so the loop cannot
        // muddy a request count that is the whole measurement.
        var cadence = RunMonitor.Cadence()
        cadence.idle = 3_600
        cadence.active = 3_600
        return RunMonitor(client: client, cadence: cadence)
    }

    /// `.explicit` needs no discovery request, and a `currentUser` skips the
    /// `/user` probe — so a poll is exactly one runs request per repository and
    /// the count means something.
    static func configure(_ monitor: RunMonitor) async {
        await monitor.configure(
            repoScope: .explicit, repoLimit: 10, organizations: [],
            explicitRepositories: ["acme/api"], actorScope: .everyone,
            watchedActors: [], approvalsFromOthers: false, currentUser: "alice")
    }

    static func main() async {
        var failures = 0
        func assert(_ label: String, _ condition: Bool) {
            if condition { print("  ok    \(label)") }
            else { print("  FAIL  \(label)"); failures += 1 }
        }

        print("── five refreshes at once, with no loop running ──")
        // Without the in-flight guard each of these is a full poll: five rounds
        // of requests, five rounds of decodes, and a rate limit spent five
        // times over to produce one answer.
        do {
            let monitor = makeMonitor()
            await configure(monitor)
            SlowGitHub.reset(delay: 0.25)

            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<5 {
                    group.addTask { await monitor.refreshNow() }
                }
            }
            let count = SlowGitHub.runsCount
            assert("exactly one reached the wire, not five (got \(count))", count == 1)
        }

        print()
        print("── a refresh that arrives mid-flight is not thrown away ──")
        // The half that matters after a token or host change: the poll being
        // coalesced onto is about to discard its own results, so the refusal
        // has to be remembered and paid off rather than dropped.
        do {
            let monitor = makeMonitor()
            await configure(monitor)
            SlowGitHub.reset(delay: 0.4)

            await monitor.start()          // the loop polls immediately
            try? await Task.sleep(for: .milliseconds(120))  // catch it mid-flight
            await monitor.refreshNow()     // must be deferred, not dropped
            let duringFlight = SlowGitHub.runsCount
            assert("the mid-flight refresh did not start a second poll (got \(duringFlight))",
                   duringFlight == 1)

            // Long enough for the first poll to land and the loop to pay the
            // debt, but far short of the hour-long cadence, so a second round
            // can only be the deferred refresh.
            try? await Task.sleep(for: .milliseconds(1_200))
            let after = SlowGitHub.runsCount
            assert("and it was paid off once the flight ended (got \(after))", after == 2)
            assert("exactly once — a deferred refresh is not a loop", after == 2)
            await monitor.stop()
        }

        print()
        print("── with nothing owed, a finished poll stays finished ──")
        do {
            let monitor = makeMonitor()
            await configure(monitor)
            SlowGitHub.reset(delay: 0)
            await monitor.start()
            try? await Task.sleep(for: .milliseconds(600))
            let count = SlowGitHub.runsCount
            assert("one poll, and the cadence keeps it there (got \(count))", count == 1)
            await monitor.stop()
        }

        print()
        print("── a poll whose configuration changed under it stands down ──")
        // `configurationGeneration` is the other half of the re-entrancy work,
        // and the half with a crash in its history: `for index in
        // watched.indices` materialised a range, an await handed the actor to
        // `configure(_:)`, which set `watched = []`, and the resumption indexed
        // an emptied array. The snapshot fixed the crash; the generation counter
        // fixes what remained, which is quieter — a poll that finished under
        // the old settings writing the old scope's runs onto the island for a
        // cycle, seconds after somebody changed them.
        //
        // `ReentrancyVerify` covers `merged()`, the pure half. The discard
        // itself needs the actor and a poll caught in flight.
        do {
            let monitor = makeMonitor()
            await configure(monitor)
            SlowGitHub.reset(delay: 0.4)

            let polling = Task { await monitor.refreshNow() }
            try? await Task.sleep(for: .milliseconds(120))

            // Same shape as picking a different repository in Settings.
            await monitor.configure(
                repoScope: .explicit, repoLimit: 10, organizations: [],
                explicitRepositories: ["acme/other"], actorScope: .everyone,
                watchedActors: [], approvalsFromOthers: false, currentUser: "alice")

            await polling.value
            let state = await monitor.currentState()
            assert("the in-flight poll's runs never reached the island (got \(state.runs.count))",
                   state.runs.isEmpty)
            assert("and its repository list did not either",
                   !state.repositories.contains("acme/api"))
        }

        print()
        print(failures == 0
              ? "RESULT: PASS — one poll at a time, no refresh lost, no stale scope drawn"
              : "RESULT: FAIL — \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
