import Foundation

// MARK: - Tier

/// Which slice of the world a run is pointed at.
///
/// Three, because three is what people actually mean when they ask "is that
/// prod?" — and because a fourth would have to be invented for every team's
/// own vocabulary. Anything GitHub calls an environment but this cannot place
/// is `unknown`: still worth naming on the island, just not worth colouring.
public enum DeployTier: String, Sendable, Hashable, CaseIterable {
    /// Real users are downstream of this one.
    case production
    /// The rehearsal: staging, pre-prod, UAT.
    case staging
    /// Nothing anybody outside the team will notice: test, dev, QA, sandbox.
    case testing
    /// A named environment whose name means nothing to us.
    case unknown

    /// Worst-consequence-wins ordering, for a run that touches more than one.
    ///
    /// A pipeline that deploys staging *and* production is a production
    /// pipeline. Leading with the smaller of the two would be the one mistake
    /// this whole feature exists to prevent.
    public var rank: Int {
        switch self {
        case .unknown: return 0
        case .testing: return 1
        case .staging: return 2
        case .production: return 3
        }
    }
}

// MARK: - Target

/// What a run deploys to, and how confidently we know it.
///
/// The confidence is not decoration. GitHub hands over an environment name
/// for exactly one shape of run — one parked on a `pending_deployments` gate —
/// and stays silent for every other. Everything else here is read off names
/// people chose, which is a guess, and a status app that draws a guess and the
/// truth identically is a status app you stop trusting the first time it is
/// wrong about production.
public struct DeployTarget: Sendable, Hashable {
    /// Where the label came from, worst-to-best in reverse: `environment` is
    /// GitHub's own word for it, the rest are ours.
    public enum Source: String, Sendable, Hashable {
        /// `pending_deployments` — GitHub named the environment itself.
        case environment
        /// A job name, e.g. `terraform-apply (prod)`.
        case job
        /// A step name, e.g. `Deploy to production`.
        case step
        /// The workflow's name, or its file name.
        case workflow
        /// The branch the run is on, e.g. `staging`.
        case branch
    }

    /// What to print: the environment's real name when GitHub gave us one,
    /// otherwise the word we matched.
    public let name: String
    public let tier: DeployTier
    public let source: Source

    public init(name: String, tier: DeployTier, source: Source) {
        self.name = name
        self.tier = tier
        self.source = source
    }

    /// GitHub said so, rather than us reading a name and guessing.
    public var isConfirmed: Bool { source == .environment }

    /// The sentence the chip's tooltip uses, so the island always says where
    /// a label came from rather than asserting it.
    public var provenance: String {
        switch source {
        case .environment:
            return "GitHub says this run is deploying to \(name)."
        case .job:
            return "Inferred from a job named after \(name) — GitHub only names "
                + "an environment on a run that is waiting for an approval."
        case .step:
            return "Inferred from a deploy step named after \(name) — GitHub only "
                + "names an environment on a run that is waiting for an approval."
        case .workflow:
            return "Inferred from the workflow's name — GitHub only names an "
                + "environment on a run that is waiting for an approval."
        case .branch:
            return "Inferred from the branch name — GitHub only names an "
                + "environment on a run that is waiting for an approval."
        }
    }
}

// MARK: - The classifier

/// Reads an environment out of a run without asking GitHub for one.
///
/// ## Why there is anything to read
///
/// The Actions API does not tell you what a run deploys to. A workflow run
/// carries its name, its file, its branch and its jobs, and none of those
/// fields is an environment. The only endpoint that names one is
/// `pending_deployments`, and it only ever answers for a run parked on a
/// required reviewer — so a deploy that is *allowed* to proceed, which is most
/// of them, goes past without GitHub ever saying where it went.
///
/// The two other places an environment could be recovered from were both
/// rejected, and it is worth writing down why:
///
///  * `GET /repos/{o}/{r}/deployments?sha=…` carries `environment` and even a
///    `production_environment` flag, but nothing links a deployment back to
///    the *run* that made it — only to the commit, which a re-run and every
///    other workflow on that commit share. It is also a request per run.
///  * `GET /repos/{o}/{r}/environments` lists the real environment names, which
///    would turn the matching below from a guess into a lookup. But it still
///    would not say which of them *this run* is going to, and unlike every
///    other endpoint the app uses it is not documented under **Actions: Read** —
///    so it would cost a second permission to sharpen something that is already
///    right on the names teams use. `docs/environments.md` has the long form.
///
/// So: free signals only. Nothing here costs a request, and `docs/polling.md`
/// is unchanged by it.
///
/// ## What it will not do
///
/// Every repository on earth has a job called `test`. Reading that as "this
/// deploys to a test environment" would put a chip on every CI run in the
/// island, which is worse than saying nothing — the whole value of the label
/// is that it appears when something is going *somewhere*. So the vocabulary
/// is split: unambiguous words (`production`, `staging`, `preprod`) stand on
/// their own, and ambiguous ones (`test`, `dev`, `preview`) only count when a
/// deploy verb is standing next to them in the same name.
public enum DeployClassifier {

    // MARK: Vocabulary

    /// Words that mean an environment wherever they appear.
    ///
    /// `preprod` is listed before `prod` can ever be reached, which matters
    /// more than it looks: matching is on whole words, so `preprod` is never
    /// seen as a `prod` with something in front of it. Getting that backwards
    /// labels the rehearsal as the real thing.
    static let unambiguous: [String: DeployTier] = [
        "production": .production,
        "prod": .production,
        "prd": .production,
        "staging": .staging,
        "preprod": .staging,
        "preproduction": .staging,
        "stg": .staging,
        "uat": .staging,
        "sandbox": .testing,
        "ephemeral": .testing,
    ]

    /// Words that mean an environment only when something is being deployed.
    ///
    /// Each of these is a job name in half the repositories in the world.
    /// `test` is the obvious one; `stage` shows up as a build stage, `live` in
    /// `live-tests`, `preview` in a docs build.
    static let ambiguous: [String: DeployTier] = [
        "live": .production,
        "stage": .staging,
        "test": .testing,
        "tests": .testing,
        "testing": .testing,
        "dev": .testing,
        "development": .testing,
        "qa": .testing,
        "integration": .testing,
        "preview": .testing,
    ]

    /// Words that mean something is being shipped somewhere.
    ///
    /// `apply` and `terraform` are in here because infrastructure pipelines are
    /// the ones where the question matters most, and they rarely use the word
    /// "deploy" at all — `terraform-apply (prod)` is the shape.
    static let deployVerbs: Set<String> = [
        "deploy", "deploys", "deployed", "deployment", "deployments",
        "release", "releases", "ship", "publish", "promote",
        "rollout", "rollback", "apply", "provision", "migrate",
        "terraform", "tofu", "pulumi", "helm", "cd",
    ]

    // MARK: Entry points

    /// The best target for a run, or nothing at all.
    public static func target(for run: WorkflowRun) -> DeployTarget? {
        // GitHub's own answer wins outright, and is the only one that can.
        if let confirmed = confirmedTarget(for: run) { return confirmed }

        // Jobs first: a job name is the closest thing in the payload to the
        // step that actually deploys. Then the workflow, then the branch —
        // widening the guess one ring at a time.
        var best: DeployTarget?
        func consider(_ candidate: DeployTarget?) {
            guard let candidate else { return }
            guard let current = best else { best = candidate; return }
            if candidate.tier.rank > current.tier.rank { best = candidate }
        }

        for job in run.jobs {
            consider(inferred(from: job.name, source: .job))
            // Steps are where a deploy is most often actually named — a job
            // called `deploy` whose step says `Deploy to production` is the
            // commonest shape there is. They are also the noisiest strings in
            // the payload, so unlike everywhere else a step has to carry a
            // deploy verb of its own before any word in it counts. Without
            // that rule, `Build production bundle` — a step in half the
            // JavaScript repositories on GitHub — labels the run as a
            // production deploy.
            for step in job.steps {
                consider(inferred(from: step.name, source: .step, requiresVerb: true))
            }
        }
        consider(inferred(from: run.name ?? "", source: .workflow))
        consider(inferred(from: run.path ?? "", source: .workflow))
        consider(inferred(from: run.headBranch ?? "", source: .branch))
        return best
    }

    /// The environment GitHub named, when it named one.
    ///
    /// A run can be parked on several at once, and the same rule applies as
    /// everywhere else here: the one with the most to lose is the one the
    /// island leads with.
    static func confirmedTarget(for run: WorkflowRun) -> DeployTarget? {
        let named = run.pendingDeployments.map(\.environment.name).filter { !$0.isEmpty }
        guard !named.isEmpty else { return nil }

        let ranked = named.map { (name: $0, tier: tier(forEnvironmentName: $0)) }
        // `max(by:)` returns the LAST of equal elements, so an explicit fold
        // keeps the first environment GitHub listed when two tie — the order
        // the run's own gates are in.
        var best = ranked[0]
        for candidate in ranked.dropFirst() where candidate.tier.rank > best.tier.rank {
            best = candidate
        }
        return DeployTarget(name: best.name, tier: best.tier, source: .environment)
    }

    /// The tier for something already known to be an environment.
    ///
    /// Both vocabularies count here, ambiguous words included: an environment
    /// literally called `test` **is** a test environment. The verb requirement
    /// exists to stop a job called `test` from being read as one, and there is
    /// no job here to be confused by.
    public static func tier(forEnvironmentName name: String) -> DeployTier {
        for word in words(in: name) {
            if let tier = unambiguous[word] ?? ambiguous[word] { return tier }
        }
        return .unknown
    }

    /// A tier read out of a name people chose, or nothing.
    /// `requiresVerb` raises the bar to "something is being deployed *and* it
    /// is named" — see the call site for the step names that need it.
    static func inferred(
        from text: String,
        source: DeployTarget.Source,
        requiresVerb: Bool = false
    ) -> DeployTarget? {
        guard !text.isEmpty else { return nil }
        let words = words(in: text)
        guard !words.isEmpty else { return nil }
        let deploys = words.contains { deployVerbs.contains($0) }
        guard deploys || !requiresVerb else { return nil }

        var best: (word: String, tier: DeployTier)?
        for word in words {
            let tier: DeployTier?
            if let strong = unambiguous[word] {
                tier = strong
            } else if deploys, let weak = ambiguous[word] {
                tier = weak
            } else {
                tier = nil
            }
            guard let tier else { continue }
            guard let current = best else {
                best = (word, tier)
                continue
            }
            if tier.rank > current.tier.rank { best = (word, tier) }
        }

        guard let best else { return nil }
        return DeployTarget(name: best.word, tier: best.tier, source: source)
    }

    // MARK: Words

    /// Split a name into the words worth matching, lowercased.
    ///
    /// Whole words only, never substrings. Substring matching is the obvious
    /// implementation and it is wrong in a way that only shows up in
    /// production: `reproduction` contains `production`, `products` contains
    /// `prod`, and a repository with a `product-api` job would have every one
    /// of its builds labelled as a production deploy.
    ///
    /// Three splits, in this order:
    ///
    ///  * on anything that is not a letter or a digit — `deploy-prod (eu)`
    ///  * between letters and digits — `prod2`, `eu1`
    ///  * on camel humps, but only for a word that matched nothing whole, so
    ///    `PreProd` is read as `preprod` rather than `pre` + `prod`
    ///
    /// The camel pass also tries adjacent pairs before single humps, which is
    /// what keeps `PreProdDeploy` out of production.
    static func words(in text: String) -> [String] {
        var result: [String] = []
        for token in tokenise(text) {
            let lowered = token.lowercased()
            if isKnown(lowered) {
                result.append(lowered)
                continue
            }
            let humps = camelHumps(of: token)
            guard !humps.isEmpty else {
                result.append(lowered)
                continue
            }
            var index = 0
            while index < humps.count {
                // The pair first: `Pre` + `Prod` is one word, not two.
                if index + 1 < humps.count {
                    let pair = humps[index] + humps[index + 1]
                    if isKnown(pair) {
                        result.append(pair)
                        index += 2
                        continue
                    }
                }
                result.append(humps[index])
                index += 1
            }
        }
        return result
    }

    /// Any word in any of the three vocabularies.
    private static func isKnown(_ word: String) -> Bool {
        unambiguous[word] != nil || ambiguous[word] != nil || deployVerbs.contains(word)
    }

    /// Runs of letters and runs of digits, original case preserved.
    private static func tokenise(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var previousWasNumber: Bool?

        func flush() {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
            previousWasNumber = nil
        }

        for character in text {
            guard character.isLetter || character.isNumber else {
                flush()
                continue
            }
            if let previousWasNumber, previousWasNumber != character.isNumber { flush() }
            current.append(character)
            previousWasNumber = character.isNumber
        }
        flush()
        return tokens
    }

    /// `PreProd` → `["pre", "prod"]`. Empty for a word with no humps in it,
    /// so callers can tell "nothing to split" from "split into one".
    private static func camelHumps(of token: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for character in token {
            if character.isUppercase, !current.isEmpty {
                parts.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { parts.append(current) }
        return parts.count > 1 ? parts.map { $0.lowercased() } : []
    }
}

// MARK: - Derived

public extension WorkflowRun {
    /// Recompute `deployTarget` from everything currently attached to the run.
    ///
    /// Stamped rather than computed, for the same reason `repository` is: the
    /// answer depends on the jobs and the pending deployments, which arrive
    /// one and two requests after the run itself, and it is read several times
    /// per body pass by a view that redraws once a second. `RunMonitor` calls
    /// this once per poll, after the detail has landed.
    mutating func stampDeployTarget() {
        deployTarget = DeployClassifier.target(for: self)
    }

    /// The same run with its target stamped — for constructing runs in one
    /// expression, which is what the demo and the spikes do.
    func stampingDeployTarget() -> WorkflowRun {
        var copy = self
        copy.stampDeployTarget()
        return copy
    }
}
