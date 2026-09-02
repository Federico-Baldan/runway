// Does the island know a production deploy when it sees one — and, more
// importantly, does it keep quiet about everything else?
//
// GitHub does not put an environment on a workflow run. It names one in exactly
// one place, `pending_deployments`, and only for a run parked on a required
// reviewer; every deploy that is allowed to proceed goes past unannounced. So
// `DeployClassifier` reads the names people chose — jobs, steps, the workflow,
// the branch — and that is a guess, which makes this spike the thing standing
// between "prod" on the island and "prod" being true.
//
// Two failure modes, and they are not symmetric:
//
//   * A MISSED deploy is a chip that does not appear. Mildly annoying.
//   * A WRONG one is the island telling you a build is going to production, or
//     that the run you are watching is the staging one when it is not. That is
//     the whole feature turned into a liability, so most of what follows is
//     traps rather than happy paths.
//
//   swiftc -o /tmp/environment spike/EnvironmentVerify.swift \
//       Sources/Runway/API/Models.swift Sources/Runway/API/Approvals.swift \
//       Sources/Runway/API/DeployTarget.swift && /tmp/environment

import Foundation

@main
enum EnvironmentVerify {
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

        /// One run, one expected label. `nil` means "say nothing".
        func check(
            _ label: String,
            _ run: WorkflowRun,
            _ expected: (name: String, tier: DeployTier, source: DeployTarget.Source)?
        ) {
            let actual = DeployClassifier.target(for: run)
            switch (actual, expected) {
            case (nil, nil):
                print("  ok    \(label) -> nothing")
            case (let actual?, let expected?)
                where actual.name == expected.name
                    && actual.tier == expected.tier
                    && actual.source == expected.source:
                print("  ok    \(label) -> \(actual.name) (\(actual.tier.rawValue))")
            case (let actual?, nil):
                print("  FAIL  \(label) -> \(actual.name) (\(actual.tier.rawValue), "
                    + "\(actual.source.rawValue)), expected nothing")
                failures += 1
            case (nil, let expected?):
                print("  FAIL  \(label) -> nothing, expected \(expected.name)")
                failures += 1
            case (let actual?, let expected?):
                print("  FAIL  \(label) -> \(actual.name)/\(actual.tier.rawValue)/"
                    + "\(actual.source.rawValue), expected \(expected.name)/"
                    + "\(expected.tier.rawValue)/\(expected.source.rawValue)")
                failures += 1
            }
        }

        // MARK: The traps

        // Substring matching is the obvious implementation of all this, and it
        // is wrong in a way that only shows up on somebody else's repository.
        print("── words, never substrings ──")
        check("a job called `product-api`", run(jobs: ["build", "product-api"]), nil)
        check("a workflow called `Reproduction cases`",
              run(name: "Reproduction cases", jobs: ["build"]), nil)
        check("a branch called `products`", run(branch: "products", jobs: ["build"]), nil)
        check("a job called `predeploy`", run(jobs: ["predeploy"]), nil)

        // `preprod` is a `prod` with letters in front of it only if you match
        // substrings. Reading the rehearsal as the real thing is the single
        // most expensive mistake this file exists to prevent.
        print()
        print("── pre-production is not production ──")
        check("job `deploy-preprod`", run(jobs: ["deploy-preprod"]),
              ("preprod", .staging, .job))
        check("job `Deploy PreProd`", run(jobs: ["Deploy PreProd"]),
              ("preprod", .staging, .job))
        check("job `PreProdDeploy` (no separators at all)", run(jobs: ["PreProdDeploy"]),
              ("preprod", .staging, .job))
        check("job `deploy-preproduction`", run(jobs: ["deploy-preproduction"]),
              ("preproduction", .staging, .job))
        check("environment named `PreProd` still says PreProd",
              run(jobs: ["deploy"], pending: ["PreProd"]),
              ("PreProd", .staging, .environment))

        // Every repository on earth has a job called `test`. If that counted,
        // the island would carry a chip on every CI run it ever drew, and the
        // one thing the chip is for — noticing that something is going
        // somewhere — would be gone.
        print()
        print("── ambiguous words need a deploy verb ──")
        check("jobs `build`, `test`, `lint`", run(jobs: ["build", "test", "lint"]), nil)
        check("job `integration-test`", run(jobs: ["integration-test"]), nil)
        check("job `dev`", run(jobs: ["dev"]), nil)
        check("job `deploy-test`", run(jobs: ["deploy-test"]), ("test", .testing, .job))
        check("job `deploy preview`", run(jobs: ["deploy preview"]), ("preview", .testing, .job))
        check("branch `staging` needs no verb", run(branch: "staging"),
              ("staging", .staging, .branch))

        // Steps are the noisiest strings in the payload, so they need a verb of
        // their own whatever the word is. `Build production bundle` is a step
        // in half the JavaScript repositories on GitHub and deploys nothing.
        print()
        print("── steps need a verb, whatever the word ──")
        check("step `Build production bundle`",
              run(jobs: ["build"], steps: ["Build production bundle"]), nil)
        check("step `Run tests against staging`",
              run(jobs: ["test"], steps: ["Run tests against staging"]), nil)
        check("step `Deploy to production`",
              run(jobs: ["deploy"], steps: ["Checkout", "Deploy to production"]),
              ("production", .production, .step))

        // MARK: The shapes people actually ship

        print()
        print("── real pipelines ──")
        check("job `terraform-apply (prod)`",
              run(jobs: ["terraform-plan", "terraform-apply (prod)"]),
              ("prod", .production, .job))
        check("workflow `.github/workflows/deploy-prod.yml`",
              run(name: "infrastructure", path: ".github/workflows/deploy-prod.yml"),
              ("prod", .production, .workflow))
        check("workflow named `Deploy to production`",
              run(name: "Deploy to production", jobs: ["build"]),
              ("production", .production, .workflow))
        check("a plain CI run says nothing at all",
              run(name: "CI", path: ".github/workflows/ci.yml",
                  branch: "feat/payments", jobs: ["build", "test"],
                  steps: ["Checkout", "Set up Node", "npm ci", "npm test"]),
              nil)

        // MARK: Precedence

        // A pipeline that touches staging and production is a production
        // pipeline. Leading with the smaller of the two is the mistake with the
        // most to lose.
        print()
        print("── the one with the most to lose wins ──")
        check("jobs deploy-staging + deploy-prod",
              run(jobs: ["deploy-staging", "deploy-prod"]),
              ("prod", .production, .job))
        check("jobs in the other order",
              run(jobs: ["deploy-prod", "deploy-staging"]),
              ("prod", .production, .job))
        check("a prod job beats a staging branch",
              run(branch: "staging", jobs: ["deploy-prod"]),
              ("prod", .production, .job))
        assert("production outranks staging outranks testing outranks unknown",
               DeployTier.production.rank > DeployTier.staging.rank
                   && DeployTier.staging.rank > DeployTier.testing.rank
                   && DeployTier.testing.rank > DeployTier.unknown.rank)

        // GitHub naming an environment is the only thing here that is not a
        // guess, so it wins over every reading of every name — including one
        // that would have ranked higher.
        print()
        print("── GitHub's own word wins ──")
        check("gate on staging, job says prod",
              run(jobs: ["deploy-prod"], pending: ["staging"]),
              ("staging", .staging, .environment))
        check("two gates: production leads",
              run(jobs: ["deploy"], pending: ["staging", "production"]),
              ("production", .production, .environment))
        assert("a confirmed target says so", {
            let target = DeployClassifier.target(for: run(jobs: ["deploy"], pending: ["production"]))
            return target?.isConfirmed == true
        }())
        assert("an inferred one does not", {
            let target = DeployClassifier.target(for: run(jobs: ["deploy-production"]))
            return target?.isConfirmed == false
        }())

        // An environment GitHub named is an environment whatever it is called,
        // so the ambiguous words count here — there is no job to be confused
        // by — and a name nobody can place is still worth printing.
        print()
        print("── environment names ──")
        assert("`test` as an environment is a test environment",
               DeployClassifier.tier(forEnvironmentName: "test") == .testing)
        assert("`Production` is production",
               DeployClassifier.tier(forEnvironmentName: "Production") == .production)
        assert("`prod-eu-west-1` is production",
               DeployClassifier.tier(forEnvironmentName: "prod-eu-west-1") == .production)
        assert("`acme-tenant-7` is unknown, not a guess",
               DeployClassifier.tier(forEnvironmentName: "acme-tenant-7") == .unknown)
        check("an unplaceable environment is still named",
              run(jobs: ["deploy"], pending: ["acme-tenant-7"]),
              ("acme-tenant-7", .unknown, .environment))

        // MARK: Stamping

        // The target is stored, not computed — it depends on jobs and pending
        // deployments, which arrive one and two requests after the run. So the
        // stamp has to happen after them, and the run's change signature has to
        // move when it does or the island will not redraw.
        print()
        print("── stamped, and visible to the dedupe gate ──")
        let bare = run(jobs: ["deploy-prod"])
        assert("nothing is stamped until somebody stamps it", bare.deployTarget == nil)
        let stamped = bare.stampingDeployTarget()
        assert("stamping fills it in", stamped.deployTarget?.tier == .production)
        assert("and moves the signature", bare.signature != stamped.signature)
        assert("stamping twice changes nothing",
               stamped.signature == stamped.stampingDeployTarget().signature)

        // MARK: The user's own screenshot

        // Two runs of the same workflow in the same repository, told apart by
        // nothing the island used to draw. This is the case the feature was
        // asked for.
        print()
        print("── two runs of one workflow, told apart ──")
        let preprod = run(
            name: "syo_services_infrastructure",
            jobs: ["terraform-plan", "terraform-scan", "manual-approval", "terraform-apply (preprod)"]
        )
        let production = run(
            name: "syo_services_infrastructure",
            jobs: ["terraform-plan", "terraform-scan", "manual-approval", "terraform-apply (prod)"]
        )
        check("the pre-prod one", preprod, ("preprod", .staging, .job))
        check("the production one", production, ("prod", .production, .job))
        assert("and they no longer have the same signature",
               preprod.stampingDeployTarget().signature
                   != production.stampingDeployTarget().signature)

        print()
        if failures == 0 {
            print("RESULT: PASS — the island names an environment only when it has one")
        } else {
            print("RESULT: FAIL — \(failures) case(s) wrong")
            exit(1)
        }
    }

    // MARK: - Fixtures

    /// A run shaped like the ones the classifier sees, with only the fields it
    /// reads filled in.
    static func run(
        name: String? = "build",
        path: String? = ".github/workflows/build.yml",
        branch: String? = "main",
        jobs: [String] = [],
        steps: [String] = [],
        pending: [String] = []
    ) -> WorkflowRun {
        let stepList = steps.enumerated().map { index, stepName in
            Step(name: stepName, number: index + 1, status: .success)
        }
        // Steps hang off the first job, which is where they hang in the API.
        let jobList = jobs.enumerated().map { index, jobName in
            Job(
                id: 1_000 + index,
                name: jobName,
                status: .success,
                steps: index == 0 ? stepList : []
            )
        }
        return WorkflowRun(
            id: 4_242,
            name: name,
            path: path,
            runNumber: 17,
            headBranch: branch,
            status: .success,
            repository: "acme/infra",
            jobs: jobList,
            pendingDeployments: pending.map {
                PendingDeployment(environment: PendingDeployment.Environment(id: 1, name: $0))
            }
        )
    }
}
