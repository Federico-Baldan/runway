import Foundation

/// Errors surfaced to the UI. Never carries the token.
public enum GitHubError: Error, LocalizedError, Sendable, Equatable {
    case noToken
    case unauthorized
    case forbidden(String)
    /// The org enforces SAML SSO and this token was never authorized for it.
    /// Carries the one-hour authorization URL GitHub puts in `X-GitHub-SSO`.
    case singleSignOnRequired(authorizeURL: String?)
    case notFound(String)
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(status: Int)
    case network(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .noToken:
            return "No GitHub token. Add a fine-grained token with Actions: Read in Settings."
        case .unauthorized:
            return "Token rejected by GitHub. Check that it is valid and not expired."
        case .forbidden(let detail):
            return detail.isEmpty
                ? "GitHub refused the request. The token may be missing the Actions: Read permission."
                : "GitHub refused the request: \(detail)"
        case .singleSignOnRequired:
            return "This organization enforces SAML single sign-on, and this token "
                + "has not been authorized for it. Authorizing takes one click on GitHub."
        case .notFound(let path):
            return "Not found: \(path). The repository may be private to your token."
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "Rate limited by GitHub. Retrying in \(Int(retryAfter))s."
            }
            return "Rate limited by GitHub. Backing off."
        case .serverError(let status):
            return "GitHub returned HTTP \(status)."
        case .network(let message):
            return "Network error: \(message)"
        case .decoding(let message):
            return "Could not read GitHub's response: \(message)"
        }
    }

    /// Transient failures that deserve exponential backoff rather than a hard stop.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .serverError, .network:
            return true
        case .noToken, .unauthorized, .forbidden, .singleSignOnRequired, .notFound, .decoding:
            return false
        }
    }
}

/// A response that may have been served from the conditional cache.
public struct Conditional<Value: Sendable>: Sendable {
    public let value: Value
    /// True when GitHub answered `304 Not Modified` and this cost no rate limit.
    public let notModified: Bool

    public init(value: Value, notModified: Bool) {
        self.value = value
        self.notModified = notModified
    }
}

/// What GitHub's `X-GitHub-SSO` header said on the last response.
///
/// This header is the only signal the API gives about SAML single sign-on, and
/// it comes in two shapes that behave *completely* differently:
///
///  * **`required`** — sent with a `403` when the request named one org
///    directly (`/orgs/{org}/repos`). A hard failure, and the header carries a
///    URL that authorizes the token. That URL expires after one hour.
///  * **`partial-results`** — sent with a **`200`** when the request could span
///    several orgs (`/user/repos`, `/user/orgs`). GitHub quietly drops the
///    unauthorized org's rows and returns the rest. Nothing fails. The list is
///    just short, and without reading this header the app cannot tell the
///    difference between "you are in no orgs" and "your token was never
///    authorized for the org you are in".
///
/// The second case is why this type exists: it is the difference between a
/// blank organization picker and a blank picker that explains itself.
///
/// Documented at
/// <https://docs.github.com/en/rest/authentication/authenticating-to-the-rest-api>
/// under "Authenticating with a personal access token".
public enum SSONotice: Sendable, Equatable {
    /// A single-org request was refused outright. `url` authorizes the token.
    case required(url: String?)
    /// A cross-org list came back missing these organizations' rows.
    /// GitHub identifies them by numeric id, not by login.
    case partialResults(organizationIDs: [String])

    /// Parse the header value. `nil` when there is nothing to say.
    ///
    /// Deliberately tolerant about the exact syntax: GitHub documents the
    /// `partial-results` form verbatim but never spells out the `required`
    /// one, so this reads whichever directives are present rather than
    /// matching a fixed string.
    public static func parse(_ header: String?) -> SSONotice? {
        guard let header, !header.isEmpty else { return nil }

        var kind = ""
        var directives: [String: String] = [:]
        for (index, part) in header.split(separator: ";").enumerated() {
            let piece = part.trimmingCharacters(in: .whitespaces)
            // Split on the FIRST `=` only: the authorize URL contains one of
            // its own (`?authorization_request=...`).
            if let separator = piece.firstIndex(of: "=") {
                let key = String(piece[piece.startIndex..<separator])
                    .trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(piece[piece.index(after: separator)...])
                    .trimmingCharacters(in: .whitespaces)
                directives[key] = value
            } else if index == 0 {
                kind = piece.lowercased()
            }
        }

        if kind == "partial-results" || directives["organizations"] != nil {
            let ids = (directives["organizations"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return .partialResults(organizationIDs: ids)
        }
        if kind == "required" || directives["url"] != nil {
            return .required(url: directives["url"])
        }
        return nil
    }

    /// The authorization URL, when GitHub offered one.
    public var authorizeURL: String? {
        if case .required(let url) = self { return url }
        return nil
    }
}

/// Talks to GitHub's REST API over URLSession. No `gh`, no subprocess.
///
/// REST rather than GraphQL, which is the opposite of the GitLab original. The
/// reason is `checkSuites`: GitHub's GraphQL exposes Actions only through the
/// check-suite graph, which does not carry `run_attempt`, needs a nested
/// connection per repository anyway, and costs more rate-limit points than the
/// equivalent REST calls. REST also gives ETags per endpoint, which is what
/// makes the poll affordable at all — see `ETagStore`.
public actor GitHubClient {
    /// The REST API version this client is written against. Pinning it means a
    /// future breaking change lands as a deliberate bump rather than a mystery
    /// decoding failure one morning.
    public static let apiVersion = "2026-03-10"

    /// Public GitHub. Enterprise Server installs use `https://HOST/api/v3`.
    public static let defaultBaseURL = URL(string: "https://api.github.com")!

    /// The session every client uses unless one is injected.
    ///
    /// **Not `URLSession.shared`, and that is the whole point.** The shared
    /// session carries the shared `URLCache`, which on macOS is backed by a
    /// several-hundred-megabyte on-disk store — and every 200 this app receives
    /// is a cacheable `GET` that lands in it. Runway polls up to a hundred
    /// repositories, and a run list at `per_page=30` is a substantial JSON
    /// body, so an app whose entire reason for existing is to be cheap was
    /// quietly writing GitHub's API to disk all day.
    ///
    /// None of it was ever read back, either. `get(_:)` sets
    /// `.reloadIgnoringLocalCacheData` on every request precisely so the URL
    /// cache cannot answer one — the conditional-request machinery in
    /// `ETagStore` depends on seeing GitHub's own 304, which a cache hit would
    /// hide. That flag governs the *request* only; the response was still being
    /// stored. So the store was pure cost: bytes on disk, and the I/O to put
    /// them there, for a cache with no reader.
    ///
    /// An ephemeral configuration has no disk store at all, which also means
    /// the token never reaches a persistent cookie or credential file.
    nonisolated public static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // The poll is serial by design — see `fetchRepositories` — so a wide
        // connection pool buys nothing and only holds sockets open.
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// Mutable, because the GitHub instance is a setting. See `setBaseURL`.
    private var baseURL: URL
    private let session: URLSession
    private let tokenProvider: @Sendable () -> String?

    private var etags = ETagStore()
    private var rateLimit = RateLimit()
    /// The most recent `X-GitHub-SSO` notice, so the UI can explain a list that
    /// came back short.
    ///
    /// Written only by the requests that can carry one — the repository and
    /// organization lists, marked `tracksSSO` — and written on every one of
    /// them, absence included. Both halves matter. Letting every endpoint
    /// write it would have `fetchRuns` clear the notice moments after
    /// `fetchRepositories` set it, since a per-repository 200 has no header to
    /// report; never clearing it would leave the warning on screen forever
    /// after the user authorized the token, which is a worse lie than the
    /// silence this replaced.
    private var ssoNotice: SSONotice?

    private let decoder: JSONDecoder = {
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
    }()

    public init(
        baseURL: URL = GitHubClient.defaultBaseURL,
        session: URLSession = GitHubClient.sharedSession,
        tokenProvider: @escaping @Sendable () -> String? = { TokenCache.shared.token() }
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
    }

    /// Build an API base URL from a host string in Settings.
    ///
    /// `github.com` is special-cased: its API lives on `api.github.com`, while
    /// every Enterprise Server install serves it from `/api/v3` on the same
    /// host. Getting this wrong produces a 404 on the HTML site rather than an
    /// obvious error, so it is handled in one place.
    public static func baseURL(for host: String) -> URL {
        var trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return defaultBaseURL }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }

        guard let url = URL(string: trimmed), let hostName = url.host else {
            return defaultBaseURL
        }
        if hostName == "github.com" || hostName == "www.github.com" || hostName == "api.github.com" {
            return defaultBaseURL
        }
        if trimmed.hasSuffix("/api/v3") { return URL(string: trimmed) ?? defaultBaseURL }
        return URL(string: trimmed + "/api/v3") ?? defaultBaseURL
    }

    /// The web origin matching this API base, for building browser links.
    public static func webOrigin(for host: String) -> String {
        let base = baseURL(for: host)
        guard let hostName = base.host else { return "https://github.com" }
        if hostName == "api.github.com" { return "https://github.com" }
        // The port comes along. An Enterprise Server reachable on anything but
        // 443 would otherwise have "Open GitHub Token Settings" open a host that
        // is not listening — and the API calls, which keep the port, would go on
        // working, so the one broken thing is the button that explains how to
        // fix the token.
        let port = base.port.map { ":\($0)" } ?? ""
        return "https://" + hostName + port
    }

    // MARK: - Rate limit

    public func currentRateLimit() -> RateLimit { rateLimit }

    // MARK: - Single sign-on

    /// What GitHub last said about SAML SSO, if anything.
    public func currentSSONotice() -> SSONotice? { ssoNotice }

    /// Forget every cached ETag. Must run on token change: ETags are per-token.
    ///
    /// The SSO notice goes with them, and for the same reason: it describes
    /// what *that* token was authorized for.
    public func invalidateCache() {
        etags.invalidate()
        ssoNotice = nil
    }

    /// Point this client at a different GitHub instance.
    ///
    /// The host is a setting, and every cached ETag, every rate-limit reading
    /// and the SSO notice describe the server that issued them — so moving is
    /// not a matter of swapping a URL and carrying on. The rate limit is reset
    /// rather than left stale because the numbers are per-instance and the
    /// monitor reads `isTight` off them to decide how often to poll: an
    /// Enterprise Server's budget arrives with the first response, and until it
    /// does, a public-GitHub reading of "40 left" would have the poll conserving
    /// against a limit that does not apply to it.
    public func setBaseURL(_ url: URL) {
        guard url != baseURL else { return }
        baseURL = url
        invalidateCache()
        rateLimit = RateLimit()
    }

    // MARK: - Account

    /// Cheap auth probe. Also how `@me` gets resolved to a real login.
    public func fetchAuthenticatedUser() async throws -> AuthenticatedUser {
        try await get(path: "/user", cacheKey: "user").value
    }

    /// Organizations the account belongs to, for the organization picker.
    public func fetchOrganizations() async throws -> [Organization] {
        try await get(path: "/user/orgs", query: [.init(name: "per_page", value: "100")],
                      cacheKey: "orgs", tracksSSO: true).value
    }

    /// Confirm a login typed into the actor list actually exists.
    public func fetchUser(login: String) async throws -> GitHubActor {
        let escaped = login.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? login
        return try await get(path: "/users/\(escaped)", cacheKey: "user:\(login)").value
    }

    // MARK: - Repositories

    /// Repositories to poll, resolved from the configured scope.
    ///
    /// `sort=pushed` is the whole trick behind `.recent`: GitHub orders by last
    /// push server-side, so the repositories you are actually working in are on
    /// page one and the long tail never gets fetched.
    public func fetchRepositories(
        scope: RepoScope,
        limit: Int,
        organizations: Set<String>,
        explicit: [String]
    ) async throws -> [Repository] {
        switch scope {
        case .explicit:
            // Nothing to discover — the user said exactly which ones.
            return explicit
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.contains("/") }
                .map { Repository(fullName: $0) }

        case .recent, .contributor, .mine:
            // The three scopes that are one `/user/repos` request apart, told
            // apart by `affiliation` alone — see `RepoScope.affiliation`.
            guard let affiliation = scope.affiliation else { return [] }
            return try await userRepositories(affiliation: affiliation, limit: limit)

        case .organizations:
            guard !organizations.isEmpty else { return [] }
            var result: [Repository] = []
            // Serially, per GitHub's own guidance: concurrent requests from one
            // account trip the secondary rate limit long before the primary one.
            for org in organizations.sorted() {
                let escaped = org.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? org
                let page: [Repository] = try await get(
                    path: "/orgs/\(escaped)/repos",
                    query: [
                        .init(name: "sort", value: "pushed"),
                        .init(name: "direction", value: "desc"),
                        .init(name: "per_page", value: "\(min(limit, 100))"),
                    ],
                    cacheKey: "orgrepos:\(org)",
                    tracksSSO: true
                ).value
                result.append(contentsOf: page)
            }
            return Array(sortedByPush(result).prefix(limit))
        }
    }

    private func userRepositories(affiliation: String, limit: Int) async throws -> [Repository] {
        let repos: [Repository] = try await get(
            path: "/user/repos",
            query: [
                .init(name: "sort", value: "pushed"),
                .init(name: "direction", value: "desc"),
                .init(name: "affiliation", value: affiliation),
                .init(name: "per_page", value: "\(min(max(limit, 1), 100))"),
            ],
            cacheKey: "repos:\(affiliation)",
            tracksSSO: true
        ).value
        return Array(sortedByPush(repos).prefix(limit))
    }

    /// Drop archived repositories and order by push recency.
    ///
    /// Archived repos cannot run Actions but still come back from `/user/repos`,
    /// so leaving them in would spend a request per cycle guaranteed to return
    /// nothing.
    private func sortedByPush(_ repos: [Repository]) -> [Repository] {
        repos
            .filter { !$0.isArchived }
            .sorted { ($0.pushedAt ?? .distantPast) > ($1.pushedAt ?? .distantPast) }
    }

    // MARK: - Workflow runs

    /// Recent workflow runs for one repository.
    ///
    /// `actorLogin` maps to the `?actor=` query parameter. Exposed because it
    /// is part of the endpoint, but **`RunMonitor` never passes it**: the
    /// parameter matches whoever created the push, not the run's `actor`, so it
    /// cannot see a run somebody else pushed and you re-ran. `ActorFilter`
    /// carries the measurements behind that decision.
    public func fetchRuns(
        repository: String,
        actorLogin: String? = nil,
        perPage: Int = 10
    ) async throws -> Conditional<WorkflowRunsPayload> {
        var query: [URLQueryItem] = [
            .init(name: "per_page", value: "\(max(min(perPage, 100), 1))"),
            // Pull requests carry a large `pull_requests` array the island never
            // reads. Excluding it makes the payload — and so the decode — smaller.
            .init(name: "exclude_pull_requests", value: "true"),
        ]
        if let actorLogin, !actorLogin.isEmpty {
            query.append(.init(name: "actor", value: actorLogin))
        }

        let key = "runs:\(repository):\(actorLogin ?? "*"):\(perPage)"
        let response: Conditional<WorkflowRunsPayload> = try await get(
            path: "/repos/\(repository)/actions/runs",
            query: query,
            cacheKey: key
        )

        // The per-repo endpoint does not repeat the repository on each run.
        //
        // The deploy target is stamped in the same pass, off the run's own
        // names alone. `RunMonitor` stamps it again once the jobs have landed,
        // and that answer is the better one — but a run the actor filter is
        // hiding never gets jobs at all, and widening the filter in Settings
        // puts it on the island immediately. Without this it would sit there
        // with no environment on it until the next poll.
        let stamped = response.value.workflowRuns.map { run -> WorkflowRun in
            var copy = run
            copy.repository = repository
            copy.stampDeployTarget()
            return copy
        }
        return Conditional(
            value: WorkflowRunsPayload(totalCount: response.value.totalCount, workflowRuns: stamped),
            notModified: response.notModified
        )
    }

    /// Jobs (and their steps) for one run.
    ///
    /// A second request per run, so the monitor only asks for runs worth
    /// drawing detail for — see `RunMonitor.shouldFetchJobs`. `filter=latest`
    /// returns the current attempt rather than every historical one.
    public func fetchJobs(repository: String, runID: Int) async throws -> Conditional<[Job]> {
        let response: Conditional<JobsPayload> = try await get(
            path: "/repos/\(repository)/actions/runs/\(runID)/jobs",
            query: [
                .init(name: "filter", value: "latest"),
                .init(name: "per_page", value: "50"),
            ],
            cacheKey: "jobs:\(repository):\(runID)"
        )
        return Conditional(value: response.value.jobs, notModified: response.notModified)
    }

    /// Environments one run is parked on, waiting for a human.
    ///
    /// A third request per run, and by far the rarest: it is only ever asked
    /// for a run that has already said it is `waiting` or `action_required` —
    /// see `RunMonitor.shouldFetchApprovals`. On a normal poll it is not sent
    /// at all, so the rate-limit arithmetic in `docs/polling.md` is unchanged.
    ///
    /// **Actions: Read** covers it. GitHub's permissions reference lists this
    /// endpoint under the same repository permission as `/actions/runs` and
    /// `/actions/runs/{id}/jobs`, which is what makes reading approvals free in
    /// the only currency that matters here — what the token is allowed to do.
    /// The `POST` that *grants* an approval is a different story (Deployments:
    /// write), and Runway does not make it.
    public func fetchPendingDeployments(
        repository: String,
        runID: Int
    ) async throws -> Conditional<[PendingDeployment]> {
        try await get(
            path: "/repos/\(repository)/actions/runs/\(runID)/pending_deployments",
            cacheKey: "pending:\(repository):\(runID)"
        )
    }

    /// Who has already answered this run's deployment gates, and how.
    ///
    /// The endpoint that makes `RunStatus.rejected` possible. Same **Actions:
    /// Read** permission as `/actions/runs` and `pending_deployments` — GitHub
    /// lists all three together — so the one thing the runs list cannot tell
    /// you about a red run costs nothing on the token.
    ///
    /// Rarer even than `fetchPendingDeployments`, and permanently cached by the
    /// monitor once it answers: it is only ever asked about a run that has
    /// already finished, and a finished run's review history does not move
    /// again. See `RunMonitor.shouldFetchReviewHistory`.
    public func fetchReviewHistory(
        repository: String,
        runID: Int
    ) async throws -> Conditional<[DeploymentReview]> {
        try await get(
            path: "/repos/\(repository)/actions/runs/\(runID)/approvals",
            cacheKey: "approvals:\(repository):\(runID)"
        )
    }

    // MARK: - Transport

    /// One conditional GET, decoded.
    private func get<T: Decodable & Sendable>(
        path: String,
        query: [URLQueryItem] = [],
        cacheKey: String,
        tracksSSO: Bool = false
    ) async throws -> Conditional<T> {
        // Checked before anything else: an unauthenticated 304 *does* count
        // against the rate limit, so a missing token must never reach the wire.
        guard let token = tokenProvider(), !token.isEmpty else {
            throw GitHubError.noToken
        }

        // Every entry holds a full response body, and the `jobs:` key carries a
        // run id — so the store mints a new entry per run and keeps it. Nothing
        // was enforcing the hour-long window the store documents, which made it
        // grow for as long as the app stayed open.
        etags.pruneIfDue()

        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw GitHubError.network("Could not build a URL for \(path).")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw GitHubError.network("Could not build a URL for \(path).")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Runway", forHTTPHeaderField: "User-Agent")
        // URLSession keeps its own HTTP cache, which would answer from disk and
        // hide the 304 the rate-limit exemption depends on. ETags are handled
        // here instead, so the URL cache must stay out of the way. Belt to
        // `sharedSession`'s braces, which has no cache to answer from — an
        // injected session may still have one.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag = etags.etag(for: cacheKey) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GitHubError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw GitHubError.network("Non-HTTP response.")
        }

        absorbRateLimitHeaders(http, billed: http.statusCode != 304)

        // Read before the status switch: `partial-results` arrives on a 200,
        // where nothing else would ever look for it.
        let sso = SSONotice.parse(http.value(forHTTPHeaderField: "X-GitHub-SSO"))
        // A 304 is excluded because it reports nothing new by definition — the
        // absence of a header on an unchanged response is not evidence that
        // the organization came back.
        if tracksSSO, http.statusCode != 304 { ssoNotice = sso }

        switch http.statusCode {
        case 200:
            etags.store(key: cacheKey, etag: http.value(forHTTPHeaderField: "ETag"), body: data)
            return Conditional(value: try decode(T.self, from: data), notModified: false)

        case 304:
            // Free, but only if a body was cached. If it was evicted, drop the
            // ETag so the next attempt is unconditional and repopulates it.
            guard let cached = etags.body(for: cacheKey) else {
                etags.store(key: cacheKey, etag: nil, body: Data())
                throw GitHubError.network("Cache miss on a 304 for \(path).")
            }
            etags.touch(key: cacheKey)
            return Conditional(value: try decode(T.self, from: cached), notModified: true)

        case 401:
            throw GitHubError.unauthorized

        case 403, 429:
            // 403 is overloaded: it is both "you lack the permission" and, with
            // the rate-limit headers set, "you ran out of budget". The headers
            // are what tell them apart.
            let remaining = Int(http.value(forHTTPHeaderField: "x-ratelimit-remaining") ?? "")
            let retryAfter = TimeInterval(http.value(forHTTPHeaderField: "retry-after") ?? "")
            if http.statusCode == 429 || remaining == 0 || retryAfter != nil {
                throw GitHubError.rateLimited(retryAfter: retryAfter ?? secondsUntilReset(http))
            }
            // A SAML org refusing an unauthorized token is a 403 like any
            // other, and reads as a permissions problem unless this header is
            // checked. It is not: the token is fine, it just needs one click.
            if case .required(let url) = sso {
                throw GitHubError.singleSignOnRequired(authorizeURL: url)
            }
            throw GitHubError.forbidden(messageFromBody(data))

        case 404:
            throw GitHubError.notFound(path)

        case 500...599:
            throw GitHubError.serverError(status: http.statusCode)

        default:
            throw GitHubError.serverError(status: http.statusCode)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw GitHubError.decoding(error.localizedDescription)
        }
    }

    /// Pull the `x-ratelimit-*` headers off a response.
    private func absorbRateLimitHeaders(_ http: HTTPURLResponse, billed: Bool) {
        if let limit = Int(http.value(forHTTPHeaderField: "x-ratelimit-limit") ?? "") {
            rateLimit.limit = limit
        }
        if let remaining = Int(http.value(forHTTPHeaderField: "x-ratelimit-remaining") ?? "") {
            rateLimit.remaining = remaining
        }
        if let reset = Double(http.value(forHTTPHeaderField: "x-ratelimit-reset") ?? "") {
            rateLimit.resetsAt = Date(timeIntervalSince1970: reset)
        }
        if billed {
            rateLimit.billedRequests += 1
        } else {
            rateLimit.savedRequests += 1
        }
    }

    private func secondsUntilReset(_ http: HTTPURLResponse) -> TimeInterval? {
        guard let reset = Double(http.value(forHTTPHeaderField: "x-ratelimit-reset") ?? "") else {
            return nil
        }
        let seconds = Date(timeIntervalSince1970: reset).timeIntervalSinceNow
        return seconds > 0 ? seconds : nil
    }

    /// GitHub puts a human-readable reason in the body of a 403.
    private func messageFromBody(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? String else { return "" }
        return message
    }
}

// MARK: - Date parsing

/// GitHub timestamps are ISO-8601 with a `Z` offset. A few endpoints add
/// fractional seconds, so both shapes are accepted.
enum GitHubDate {
    /// Built once and never reconfigured.
    ///
    /// `ISO8601DateFormatter` is expensive to construct — it builds an ICU
    /// formatter underneath — and the decoder reaches `parse` once per date
    /// field. Across twenty repositories of runs, then their jobs and steps,
    /// that is thousands of calls per poll, each of which used to allocate a
    /// formatter, fail a parse against it, mutate its options and parse again.
    ///
    /// `nonisolated(unsafe)` because `ISO8601DateFormatter` is not `Sendable`.
    /// What makes sharing it safe is Foundation's own guarantee: a formatter is
    /// safe to use from several threads as long as nothing reconfigures it
    /// after construction, which is why the options are set inside the
    /// initialiser and `formatOptions` is never touched again.
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Whole seconds first: that is the shape every run, job and step timestamp
    /// arrives in, so the fractional form is the fallback rather than the first
    /// guess. The old order failed a parse on nearly every date it was given.
    static func parse(_ raw: String) -> Date? {
        if let date = plain.date(from: raw) { return date }
        return fractional.date(from: raw)
    }
}
