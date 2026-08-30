# Filtering by user

The feature this port exists for. GitLab's version of the app had two options —
your runs or everyone's. GitHub makes a third worth having, and makes the second
one harder than it looks.

## GitHub records two people per run

```json
{
  "run_attempt": 2,
  "actor":            { "login": "alice" },
  "triggering_actor": { "login": "federico" }
}
```

`actor` is whoever caused the run to exist — normally the person who pushed.
`triggering_actor` is whoever caused *this attempt*. They are the same on a
first run and diverge the moment somebody clicks **Re-run**.

Filtering on one of them alone is wrong in both directions:

- Match only `actor`, and re-running a colleague's failed deploy leaves you with
  no island for a job you are now personally waiting on.
- Match only `triggering_actor`, and your own push disappears the moment someone
  else re-runs it.

So `WorkflowRun.involves(_:)` matches either. `spike/ActorFilterVerify.swift`
pins that down with the re-run case spelled out.

## Why `?actor=` is not used

The REST API offers what looks like free server-side filtering:

```
GET /repos/{owner}/{repo}/actions/runs?actor=alice
```

The first version of this used it whenever exactly one person was watched. Two
measurements against the live API killed the idea.

**It does not match `actor.login`.** Filtering `Homebrew/brew` by one maintainer
returned 100 runs, two of which had a completely different `actor.login`:

```
?actor=MikeMcQuaid  ->  98 runs actor=MikeMcQuaid
                         2 runs actor=Copilot
```

It is filtering — `?actor=torvalds` returns 0 — just not on the field the island
displays. The documented meaning is "the login for the user who created the push
associated with the check suite or workflow run", which is related to, but not
the same as, the run's attribution.

**It cannot see a re-run.** Since it keys off the push author, a run that a
colleague pushed and *you* re-ran does not come back from `?actor=<you>`. And
unlike the leak above, this failure is unrecoverable: the run never reaches the
local filter to be rescued. It would break the re-run case described above
precisely under **Only my runs**, the default setting — the situation where it
matters most and would be noticed least.

**It saved nothing anyway.** `per_page` is free:

```
per_page=10   -> remaining 4933
per_page=30   -> remaining 4932
per_page=100  -> remaining 4931
```

Each is one request. Filtering server-side reduces payload, never budget. So
Runway fetches one *wider* unfiltered page — 30 runs — and filters locally. Same
cost, no silent drops, and a single code path instead of two.

The residual limitation is honest and worth stating: those 30 runs are the 30
most recent by *anyone*, so a repository with more than 30 runs in the last few
minutes could push a watched person's run off the page. That is far beyond what
an island can usefully display anyway.

## `@me` before the token is verified

`@me` is a placeholder resolved against `GET /user`, which has not answered yet
on the first launch after a token change. Resolving it to an empty set would
filter out every run — an app that looks broken, with no error to explain it.

`ActorFilter.resolve` degrades to "everyone" instead whenever the list resolves
to nothing:

```swift
return resolved.isEmpty ? .everyone : ActorFilter(logins: resolved)
```

Showing too much for a few seconds is a much better failure than showing nothing
forever. The same rule covers an empty watch list and `.me` with no known login.

## Where the names come from

Typing a username by hand is the obvious way to get a typo that silently matches
nothing. Two things guard against that:

- **Validation.** Adding a name calls `GET /users/{login}` and refuses one that
  does not exist. `@me` skips the lookup, since it is not a login yet.
- **Suggestions.** Every poll collects the logins it saw into
  `MonitorState.knownActors`, and Settings offers the ones you are not already
  watching. It costs no extra request — the names were in the response already.
