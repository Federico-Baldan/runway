# Runway

GitHub Actions runs, live in the macOS notch.

The island shows up when a workflow starts, tracks it job by job, and disappears
when it's done. Hover for the full breakdown, click to open the run on GitHub.

On a display without a notch it sits under the menu bar instead, as a pill.

macOS 14+, Swift 6, no third-party dependencies.

## Whose runs

The setting the rest of the app is built around. Being in a company's org does
not mean you want every colleague's push in your menu bar — but it also doesn't
mean you only want your own. Three options:

| Option | What you get |
|---|---|
| **Only my runs** | Your pushes, and anything you re-ran. The default. |
| **Everyone's runs** | Every run in the watched repositories. |
| **Specific people** | A list you pick. `@me` resolves to whoever the token belongs to. |

A re-run counts for **both** people: GitHub records the person who pushed as
`actor` and the person who clicked *Re-run* as `triggering_actor`, and Runway
matches either. So if you re-run a colleague's failed deploy, it shows up in
your island — which is what you want, since you are now the one waiting on it.

Filtering happens locally, from the 30 most recent runs in each repository.
GitHub does offer an `?actor=` parameter, and Runway deliberately doesn't use
it: measured against the live API it matches the *push author* rather than the
run's actor, so it cannot see a run somebody else pushed and you re-ran — the
exact case above, under the default setting. It also saves nothing, since
`per_page` 10 and 100 cost the same single request. [`docs/actors.md`](docs/actors.md)
has the measurements.

## Install

```bash
brew tap Federico-Baldan/runway https://github.com/Federico-Baldan/runway
brew install Federico-Baldan/runway/runway
```

This repository is its own Homebrew tap — there is no separate `homebrew-tap`
repo. Homebrew reads formulae from a tap's `Formula/` directory, and `brew tap`
accepts an explicit URL for repositories not named `homebrew-*`. The `tap` line
is a one-off; after that `brew upgrade` works normally.

No Xcode required: the app is built by CI and Homebrew unpacks it.

A **formula** shipping a prebuilt app, not a cask, and that is deliberate. The
app is ad-hoc signed but not notarized, because notarizing needs a $99/year
Apple Developer ID. Gatekeeper only asks about notarization for a file carrying
`com.apple.quarantine` — and quarantine is applied by the *cask* installer, not
by formulae. So a cask of this app would send you to System Settings → Privacy
& Security → Open Anyway on first launch, and the formula does not.

The same reasoning means you should **not** grab `Runway.zip` from the releases
page and unzip it yourself: a browser download is quarantined and will hit that
wall. Install through brew.

The one thing a Developer ID would buy: an ad-hoc signature is pinned to the
binary's cdhash, which changes every build, so macOS treats each upgrade as a
new app and asks for keychain access again to reach your token. Compiling
locally had the same problem — it is the price of not paying Apple $99.

Or from source, without Homebrew (this is the path that needs Xcode 16+):

```bash
git clone https://github.com/Federico-Baldan/runway
cd runway
make signing-identity   # once, stops repeated keychain prompts (not with sudo)
make app
open .build/debug/Runway.app
```

## The token

Click the menu bar icon, open Settings, and paste a **fine-grained** personal
access token with:

| Permission | Level |
|---|---|
| Actions | Read |
| Metadata | Read (mandatory, granted automatically) |

**Actions: Read is the only box you tick.** Runway calls exactly two repository
endpoints — `/actions/runs` and `/actions/runs/{run_id}/jobs` — and GitHub lists
both under the Actions read permission. It never reads your code, so Contents is
not needed. Everything it does is a GET; nothing needs write.

What matters more than the permission is the **repository selection**: a
fine-grained token only reaches the repositories you explicitly pick when
creating it. Runway can watch nothing else, whatever the permissions say.

There's a button in Settings that opens the token page. A classic token with
the `repo` scope also works.

### Organizations, and the failure that looks like success

If your organization enforces SAML single sign-on, a token that authenticates
perfectly can still see none of its repositories, because GitHub does not report
this as an error:

* A **classic** token must be authorized for each SAML organization *after* it
  is created — open the token, then **Configure SSO → Authorize**. Until you do,
  `/user/repos` and `/user/orgs` return **`200 OK`** with that organization's
  rows quietly removed. The only trace is an `X-GitHub-SSO: partial-results`
  header. Nothing fails; the list is just short.
* A **fine-grained** token belongs to exactly one resource owner. Created
  against your personal account it can never see an organization, whatever its
  permissions; created against the organization it stays inert until an admin
  approves it. Again, no error — an empty list.

Runway reads that header and says so, in Settings and on the island, rather than
showing you an empty organization picker and letting you guess. `read:org`
(classic) or Organization → Members: Read (fine-grained) is what populates the
picker itself.

Your token goes in the macOS Keychain, never to disk. The app asks for keychain
access on first launch; that prompt is the whole point.

You can also provision it headlessly:

```bash
runway store github_pat_...
runway verify
```

## Which repositories

GitHub has no endpoint for "every run I can see". Its API is per-repository, so
Runway has to pick a set and poll each one — which is the main structural
difference from the GitLab project this is a port of, where a single query
answered the whole question.

**Recently active** (the default) asks GitHub for your repositories sorted by
last push and takes the top 20. That covers the real case — you are working in
two or three repos — without spending a request per cycle on the long tail. The
other options are your own repositories, selected organizations, or a list you
type yourself.

The count is a dial in Settings. It is the one knob that trades responsiveness
for API budget.

### Why the polling is affordable

Twenty repositories polled every five seconds is 14,400 requests an hour against
a budget of 5,000. Runway sends every request with an `If-None-Match` header, and
GitHub does not charge a `304 Not Modified` against the primary rate limit when
the request is authenticated. A repository that isn't building doesn't change,
so it answers 304 and costs nothing. In practice only the repository that is
actually building is billed.

Three other things keep it down: repositories with no Actions at all get demoted
to an occasional check after the first empty response, the repository list itself
is only re-discovered every five minutes, and job detail — a second request per
run — is fetched only for runs that are moving or finished in the last two
minutes, since those are the only ones the island draws.

`spike/RateBudgetVerify.swift` checks the arithmetic still holds.

## Environment variables

Handy for setting the filter per project or from a dotfile, without opening
Settings.

| Variable | Example |
|---|---|
| `RUNWAY_ACTOR_MODE` | `me`, `everyone`, `list` |
| `RUNWAY_ACTORS` | `@me,alice,bob` |
| `RUNWAY_REPO_SCOPE` | `recent`, `mine`, `organizations`, `explicit` |
| `RUNWAY_REPOS` | `acme/web,acme/api` |
| `RUNWAY_REPO_LIMIT` | `10` |
| `RUNWAY_ORGS` | `acme,acme-labs` |
| `RUNWAY_HOST` | `https://github.example.com` (Enterprise Server) |

**They are defaults, not locks.** A variable supplies the starting value for a
setting you have never touched. The moment you change that setting in the app,
your choice wins and the variable stops applying to it — every control stays
editable. Settings shows a small `RUNWAY_ACTORS` chip next to any setting a
variable seeded, and clicking it puts the setting back to the variable's value.

An earlier version let the environment win permanently and greyed the controls
out. That was the wrong call: a forgotten variable in a shell profile left you
unable to change your own settings from inside the app, with no way to fix it
from inside the app either.

Setting `RUNWAY_ACTORS` without `RUNWAY_ACTOR_MODE` implies `list`, and
`RUNWAY_REPOS` without `RUNWAY_REPO_SCOPE` implies `explicit` — otherwise the
list would be stored and then quietly ignored. Both only apply while you have
not chosen the mode yourself.

One practical note: an `LSUIElement` app launched from Finder or as a login item
does not inherit your shell environment, so these take effect when Runway starts
from a terminal (`make run`) or a launch agent. Since they only seed first-run
defaults, that matters much less than it would if they were overrides.

## Other settings

**Which display** — the options are labelled with your actual monitors.

**Haptics** — a tap when something starts, passes, or fails. Needs a Force Touch
trackpad; Settings says so plainly if you don't have one.

**Launch at login** — registers with macOS via `SMAppService`. It shows up in
System Settings → General → Login Items, and turning it off there wins: the app
reads the system state rather than its own preference.

## When nothing appears

```bash
runway --diagnose
```

It prints the displays it can see, which one it picked, the notch measurements,
the repository and actor filters *and what they resolve to*, any environment
overrides in force, and whether there's a token. "Nothing shows up" is as often
a filter as a display, so it covers both.

Worth knowing: the island only appears while a run is in progress, or briefly
after one finishes. If nothing is running, an empty notch is correct — check the
menu bar icon instead.

## Updating

```bash
brew upgrade runway
```

The app checks GitHub once a day and puts an "Update available" entry in the
menu when there's a newer release. It never downloads or installs anything
itself — Homebrew does that.

## Development

```bash
make run             # build and launch
make demo            # scripted runs: no network, no keychain, no CI minutes
make demo-notch      # same, with a simulated notch (useful lid-closed)
make spikes-offline  # regression suite, no token needed
make spikes          # the above plus the live-API checks
make verify          # exercise the whole GitHub path from the CLI
make snapshot        # render the island to a PNG
```

`make demo` exists because a real Actions run takes a minute or two and burns CI
minutes. The demo loops a passing run, a failing run, and three at once by two
different people — the last of which is how you see the per-actor labelling
without needing a colleague.

`spike/` holds small standalone programs that check assumptions. They compile
against the real sources rather than re-implementing them, so they fail when the
app changes:

| Spike | Guards |
|---|---|
| `StatusFusionVerify` | GitHub's split `status`/`conclusion` pair, where every finished run says `completed` and only `conclusion` says whether it passed |
| `ActorFilterVerify` | who is kept and who is dropped, including re-runs and unresolved `@me` |
| `RateBudgetVerify` | that the poll fits inside 5,000 requests an hour |
| `CenteringVerify` | the island being centred on the *screen*, not the visible frame — off-centre by half a Dock width otherwise |
| `NotchPlacementVerify` | the resting pill never being narrower than the cutout, and the fixed canvas containing every state |

More detail in [`docs/`](docs/).

## Publishing releases

```bash
scripts/release.sh 0.2.0
git push && git push origin v0.2.0
```

That's the whole process. The tag builds on macOS, publishes the packaged app
with its `sha256`, then rewrites `version`, `url` and `sha256` in
`Formula/runway.rb` and commits it back to `main`. Since this repo is the tap,
`brew upgrade runway` picks it up immediately.

**Nothing to set up.** An earlier design pushed the formula to a separate
`homebrew-tap` repository, which meant creating that repo, minting a token with
`Contents: Write` on it, and storing it as a secret — because a workflow's own
`GITHUB_TOKEN` is scoped to its own repository and cannot push elsewhere. Making
the repo its own tap removes all three steps: `GITHUB_TOKEN` can write here.

Two details the bump job handles, both easy to get wrong:

- A tag build checks out a **detached HEAD**, so it fetches `main` and commits
  onto its tip. Committing in place would try to move `main` back to the tagged
  commit.
- It rewrites with Python, not `sed`. `sed -i` requires a backup suffix on BSD
  and rejects one on GNU, so the same line breaks on whichever runner it wasn't
  written for.

If any of the three lines fails to match, the job exits non-zero rather than
publishing a formula that still points at the previous release.

## Credit

Runway is a GitHub Actions port of [Pipeline Island](https://github.com/Uudg/pipeline-island)
by Uudg, which does the same thing for GitLab CI. The notch geometry, panel
placement and motion design come from that project. Both are MIT.

## Licence

MIT
