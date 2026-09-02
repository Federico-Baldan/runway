# Knowing whether it is prod

## The field that does not exist

A workflow run comes back looking like this:

```json
{
  "id": 1904,
  "name": "syo_services_infrastructure",
  "path": ".github/workflows/infrastructure.yml",
  "head_branch": "main",
  "event": "push",
  "status": "in_progress",
  "conclusion": null
}
```

There is no environment on it. There is no environment on a job either, and none
on a step. GitHub knows perfectly well — the run's page on the web draws a
**Production** badge next to the deploy job — but the REST API does not put it
anywhere the island can reach.

It names one in exactly one place:

```
GET /repos/{owner}/{repo}/actions/runs/{run_id}/pending_deployments
→ [ { "environment": { "name": "PreProd" }, "current_user_can_approve": true } ]
```

and that endpoint only ever answers for a run that is *stopped*, waiting on a
required reviewer. Runway already asks it — that is where the amber approval
chip gets `production — waiting for @alice` from — so for a gated deploy the
environment name is free and certain.

Every deploy that is allowed to proceed goes past unannounced.

## What was considered instead

**`GET /repos/{o}/{r}/deployments?sha={head_sha}`** carries `environment` and
even a `production_environment` boolean, which is exactly the answer. It was
rejected on two counts. Nothing links a deployment back to the run that made it
— only to the commit, which a re-run and every other workflow on that commit
share — so recovering the link means a second request to `statuses_url` to read
`log_url`. That is two requests per run, for a run that is not blocked and so
was costing one.

**`GET /repos/{o}/{r}/environments`** lists the environments a repository
actually has, with their protection rules, and it is cheap: one request per
repository, an ETag away from free after that, for an answer that changes about
once a year. It was still rejected, on two counts.

It does not answer the question. Knowing that a repository has `production` and
`PreProd` does not say which one *this run* is deploying to — the run still has
no environment on it — so the list only sharpens the name matching below, which
is the part that already works.

And it is one more thing a token has to be allowed to do. GitHub documents
`/environments` as needing *read access to the repository* — `repo` on a classic
token — rather than the **Actions: Read** line that [`docs/auth.md`](auth.md)
spends a page teaching people to get right for everything else here. That is at
best another thing to get right when scoping a token, and at worst a silent 403
on a carefully scoped one, in exchange for sharpening a label that is already
right on the names teams use.

So: free signals only. The rate-limit arithmetic in [`polling.md`](polling.md)
is unchanged by this feature.

## The signals, in order

`DeployClassifier` reads four things, and the first one that is not a guess
wins outright:

| Source | Certainty | Example |
|---|---|---|
| `pending_deployments` | GitHub's own word | `PreProd` |
| Job name | inferred | `terraform-apply (prod)` |
| Step name | inferred, verb required | `Deploy to production` |
| Workflow name, then its file | inferred | `.github/workflows/deploy-prod.yml` |
| Branch | inferred | `staging` |

The island draws the certain one **filled** and the inferred ones **outlined**,
and every chip's tooltip says where it came from. That is not decoration: the
one thing worse than not knowing whether a run is going to production is being
told confidently that it is not.

## The rules, and the traps behind each one

Every rule here exists because the obvious implementation is wrong in a way that
only shows up on somebody else's repository. `spike/EnvironmentVerify.swift`
pins all of them.

**Whole words, never substrings.** `reproduction` contains `production`.
`products` contains `prod`. Substring matching puts a production chip on every
build in a repository with a `product-api` job.

**Longest word first, so `preprod` is never a `prod` with letters in front.**
The camel-case pass tries adjacent humps as a pair before it tries them singly,
which is what keeps `PreProdDeploy` — no separators anywhere — out of
production. Calling the rehearsal the real thing is the single most expensive
mistake this file can make.

**Ambiguous words need a deploy verb in the same name.** `test`, `tests`,
`dev`, `qa`, `integration`, `preview`, `stage` and `live` are job names in half
the repositories in existence. `deploy-test` is a deploy to a test environment;
`test` is a test. The verbs are the ones infrastructure pipelines actually use,
`apply` and `terraform` included, because `terraform-apply (prod)` is the shape
of the thing this feature was asked for.

**Step names need a verb whatever the word.** Steps are the noisiest strings in
the payload, and `Build production bundle` is a step in half the JavaScript
repositories on GitHub. It deploys nothing.

**The tier with the most to lose wins.** A pipeline that deploys staging and
then production is a production pipeline. Leading with the smaller of the two
would be the failure this whole thing exists to prevent.

**An environment GitHub named is an environment whatever it is called.** The
ambiguous words count in that case — there is no job name to be confused by, so
an environment literally called `test` is a test environment — and a name
nothing can place, like `acme-tenant-7`, is still printed. It is just drawn in
grey rather than being guessed at.

## Where it is computed

Stamped onto the run, not computed on read. It depends on the jobs and the
pending deployments, which arrive one and two requests after the run itself, and
the island reads it several times per body pass on a view that redraws once a
second.

`GitHubClient.fetchRuns` stamps it from the run's own names as it stamps the
repository, so a run the actor filter is currently hiding still has a label the
moment the filter widens. `RunMonitor.attachJobs` stamps it again once the
detail has landed, and that answer is the better one. It is part of
`WorkflowRun.signature`, so the island redraws when a guess read off a job name
is replaced by the name GitHub uses.
