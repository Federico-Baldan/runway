# Making the poll affordable

## The problem GitLab didn't have

The project this ports from asked one GraphQL query and got back every pipeline
across every project the user could see. GitHub has no equivalent. Its Actions
API is per-repository:

```
GET /repos/{owner}/{repo}/actions/runs
```

There is no account-level "what is running anywhere". So a tick becomes: pick a
set of repositories, ask each one, and stitch the answers together.

Twenty repositories at the active cadence of five seconds is 720 ticks an hour,
so 14,400 requests against an authenticated budget of 5,000. That design is
rate-limited about twenty minutes after launch.

## Conditional requests

Every request carries an `If-None-Match` header built from the ETag of the last
response for that URL. GitHub's documented behaviour:

> A conditional request does not count against your primary rate limit if a 304
> is returned and the request was made while correctly authorized.

A repository that is not building does not change, so it answers `304 Not
Modified` and costs nothing. Only the repository actually running a workflow is
billed.

Two details are load-bearing:

- **The `Authorization` header is required.** An unauthenticated 304 still
  decrements the limit. `GitHubClient.get` throws `.noToken` before building the
  request, so a missing token can never reach the wire and quietly start burning
  budget.
- **`URLSession`'s own cache has to be turned off.** With the default policy it
  can answer from disk and never send the request, hiding the 304 the exemption
  depends on. Hence `request.cachePolicy = .reloadIgnoringLocalCacheData`.

ETags are also scoped per token, so `RunMonitor.resetForNewToken()` clears the
store — otherwise the first poll after switching accounts would serve the
previous account's cached bodies.

## Three more reductions

**Quiet repositories.** A repository whose first poll returns `total_count: 0`
has no Actions at all. `WatchedRepo.shouldPoll()` demotes it to one check every
twelve cycles instead of dropping it, so adding a workflow later is still
noticed within a minute.

**Repository discovery is cached.** `/user/repos?sort=pushed` is one request and
the answer barely moves, so it is re-fetched every five minutes rather than every
tick. The learned `hasWorkflows` flag survives the refresh, or a demoted repo
would be promoted back every five minutes.

**Job detail is gated.** Jobs and steps are a second request per run. They are
fetched only for runs that are active or finished within the last two minutes —
`RunMonitor.shouldFetchJobs` — because those are the only runs the island draws.
Fetching detail for everything would roughly double the cost for rows nobody is
looking at.

Job detail is also filtered *before* it is fetched, so a colleague's run that the
actor filter is about to discard never costs a request.

## Cadence

| State | Interval |
|---|---|
| Something is building | 5s |
| Nothing is building | 15s |
| Screen asleep | 120s |
| Rate-limit headroom below 15% | 60s |
| After a retryable failure | 5s, doubling, capped at 300s |

The conserving tier backs off before GitHub has to say no. Conditional requests
usually mean it never triggers, but a large watch list on a cold ETag cache can
get through the budget quickly.

A hard failure — a bad token, a missing permission — resets the failure count
rather than backing off, because retrying on a curve will never make it work. It
stops and shows the error.

## Verifying it

`spike/RateBudgetVerify.swift` runs the arithmetic: it asserts the naive number
*does* blow the budget (the reason the design exists), that the real number fits
with room to spare, and that the `RateLimit` accounting — headroom, cache hit
rate, the tight threshold — is right at the boundaries.
