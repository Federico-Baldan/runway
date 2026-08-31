# Tokens and the keychain

## Why not read `gh`'s token

The obvious shortcut for a GitHub desktop app: `gh` is already authenticated,
so read whatever it stored and skip the login flow.

Runway doesn't, for three reasons.

`gh` stores its token in the system keychain under its own service name, with an
ACL scoped to the `gh` binary. Reading another application's credential store is
indistinguishable from malware in a public repo — and it would put Runway's
access outside the user's control, since revoking it would mean revoking `gh`.

The token `gh` holds is also the wrong shape. Its OAuth token carries whatever
scopes `gh auth login` asked for, which is far more than Actions: Read. Runway
asking you for a token with two read permissions is a smaller thing to hand over
than Runway silently borrowing one that can push.

And minting a token programmatically isn't an option either — that would need a
token that can create tokens, which is the same problem one level up.

So: you create a fine-grained token, it goes in the macOS Keychain, and the app
talks to the REST API over `URLSession`. The keychain prompt on first launch is a
feature — the app cannot reach your credential without you agreeing.

## What the token needs

| Permission | Level | Why |
|---|---|---|
| Actions | Read | `/actions/runs`, `/actions/runs/{id}/jobs`, `/actions/runs/{id}/pending_deployments` |
| Metadata | Read | Mandatory on every fine-grained token; granted automatically |

**Actions: Read, and nothing else.** GitHub's own
[permissions reference](https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens)
lists all three endpoints Runway calls under "Repository permissions for
Actions", read access, with no additional permission required.

The third one is worth spelling out, because it looks like it should cost more
than it does. Reading **pending deployments** — which environments a run is
parked on, and whether this account is allowed to approve them — is Actions:
Read, the same box. *Granting* an approval is the `POST` to the same path, and
that one is Deployments: **write**. Runway never sends it: the island and the
notification both just open the run on GitHub. Asking every user for a token
that can deploy, in order to save one click, is not a trade worth making.

An earlier version of this document asked for `Contents: Read` as well. That was
wrong — the claim came from advice about *triggering* workflows, which needs
Contents because it writes a ref. Runway only reads. Asking for a permission a
program does not exercise is not a harmless default: it is the difference
between a token that can read your CI status and one that can read your source.

The account-level calls Runway makes — `GET /user`, `/user/repos`, `/user/orgs`,
`/users/{login}` — need no repository permission at all. `/user/repos` is listed
under Metadata: Read, which every fine-grained token carries.

A classic token with `repo` also works, but that scope grants read *and write*
access to code, issues and settings on every repository you can reach. Prefer
fine-grained.

Nothing Runway does is a write. Every call is a GET.

## The keychain has two backends

The modern data-protection keychain needs entitlements an ad-hoc signed app does
not have:

```
SecItemAdd(kSecUseDataProtectionKeychain: true)  →  -34018  errSecMissingEntitlement
```

That requires a paid Developer ID. So `Keychain` tries the data-protection
keychain first and falls back to the legacy file-based one, which works today
and upgrades silently if the app is ever properly signed.

The legacy keychain's per-item ACL is keyed to the writing binary's signature,
which is why the next section matters.

## Why `make signing-identity` exists

An ad-hoc signature's designated requirement is the binary's own hash:

```
designated => cdhash H"aee7ba65..."
```

That hash changes on every single build. The keychain ACL matches on it, so
macOS treats each rebuild as a brand new application and asks for your password
again. "Always Allow" only ever authorises the exact build you clicked it on —
which during development means a prompt every few minutes.

`make signing-identity` creates a local self-signed certificate. The requirement
then keys off the certificate instead, which survives rebuilds. One prompt, once.

It's a development certificate: not a Developer ID, no notarization, nothing
leaves your machine.

## Why there is no downloadable app

Signing an app for distribution needs a paid Apple Developer ID. Without one it
can only be ad-hoc signed, and macOS refuses to open a *downloaded* ad-hoc app
at all:

> "Runway is damaged and can't be opened."

Something you compiled yourself never gets the quarantine attribute, so the
problem doesn't arise. That is why Runway ships as a Homebrew **formula** that
builds from source rather than a cask that moves a prebuilt bundle — a cask
cannot compile, and a prebuilt bundle would be dead on arrival.
