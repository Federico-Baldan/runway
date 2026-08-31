// Does the app read GitHub's `X-GitHub-SSO` header the way GitHub writes it?
//
// This exists because of a bug report that looked impossible: a token that
// verifies green, an organization list that is empty, and no error anywhere.
// The cause is a documented GitHub behaviour that produces no failure at all —
// a `200` with rows quietly missing — so the only evidence is a header, and
// the only way to be wrong about it is silently.
//
// GitHub documents two shapes, and they are opposites:
//
//   X-GitHub-SSO: partial-results; organizations=21955855,20582480
//       Sent with 200 on a request that could span several orgs
//       (/user/repos, /user/orgs). The unauthorized org's rows are dropped and
//       the request succeeds. This is the case that reads as "no repositories".
//
//   X-GitHub-SSO: required; url=https://github.com/orgs/acme/sso?authorization_request=ABC
//       Sent with 403 on a request naming one org (/orgs/{org}/repos). A hard
//       failure carrying a URL that authorizes the token; it expires after an
//       hour.
//
// The `partial-results` form is quoted verbatim in GitHub's docs. The
// `required` form is described ("the X-GitHub-SSO header will include a URL
// that you can follow to authorize your token") but never written out, which
// is exactly why the parser reads directives instead of matching a fixed
// string — and why this spike pins the tolerance rather than the syntax.
//
//   https://docs.github.com/en/rest/authentication/authenticating-to-the-rest-api
//   https://docs.github.com/en/enterprise-cloud@latest/authentication/authenticating-with-single-sign-on/authorizing-a-personal-access-token-for-use-with-single-sign-on
//
//   swiftc -o /tmp/ssoverify spike/SSOVerify.swift \
//       Sources/Runway/API/GitHubClient.swift Sources/Runway/API/Models.swift \
//       Sources/Runway/API/RunScope.swift Sources/Runway/API/ETagStore.swift \
//       Sources/Runway/Auth/Keychain.swift && /tmp/ssoverify

import Foundation

@main
enum SSOVerify {
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

        print("── partial-results: the 200 that hides an organization ──")
        // Verbatim from GitHub's documentation.
        let partial = SSONotice.parse("partial-results; organizations=21955855,20582480")
        assert("the documented header parses",
               partial == .partialResults(organizationIDs: ["21955855", "20582480"]))
        assert("both organization ids survive",
               { if case .partialResults(let ids) = partial { return ids.count == 2 }
                 return false }())
        assert("it offers no authorize URL — GitHub does not send one here",
               partial?.authorizeURL == nil)

        // One org is the common case, and a trailing space is the kind of thing
        // a header rewrite would introduce.
        assert("a single organization parses",
               SSONotice.parse("partial-results; organizations=21955855")
                   == .partialResults(organizationIDs: ["21955855"]))
        assert("whitespace around the directive is tolerated",
               SSONotice.parse("partial-results;  organizations=1, 2 ")
                   == .partialResults(organizationIDs: ["1", "2"]))

        print()
        print("── required: the 403 that carries the fix ──")
        let url = "https://github.com/orgs/acme/sso?authorization_request=ABC123"
        let required = SSONotice.parse("required; url=\(url)")
        assert("the header parses as a hard requirement", required == .required(url: url))
        // The whole point: the URL contains an `=` of its own. Splitting on
        // every `=` instead of the first would truncate it at `?authorization_request`
        // and hand the user a link that does nothing.
        assert("the authorize URL survives its own query string intact",
               required?.authorizeURL == url)
        assert("`required` with no URL still reports the requirement",
               SSONotice.parse("required") == .required(url: nil))

        print()
        print("── silence means silence ──")
        assert("a missing header is not a notice", SSONotice.parse(nil) == nil)
        assert("an empty header is not a notice", SSONotice.parse("") == nil)
        assert("an unrecognised directive is not invented into one",
               SSONotice.parse("something-else") == nil)

        print()
        print("── the two cases must never be confused ──")
        // A `partial-results` treated as `required` would throw on a successful
        // request; a `required` treated as `partial-results` would swallow a
        // 403 and lose the authorize URL. Both are worse than the bug this fixes.
        assert("partial-results is not required",
               SSONotice.parse("partial-results; organizations=1") != .required(url: nil))
        assert("required is not partial-results",
               SSONotice.parse("required; url=https://x") != .partialResults(organizationIDs: []))

        print()
        print("── the error the user actually sees ──")
        let error = GitHubError.singleSignOnRequired(authorizeURL: url)
        assert("it explains SSO rather than blaming the token's permissions",
               (error.errorDescription ?? "").contains("single sign-on"))
        assert("it is not retried — no amount of backoff authorizes a token",
               !error.isRetryable)

        print()
        if failures == 0 {
            print("RESULT: PASS — both X-GitHub-SSO shapes are read as GitHub sends them")
        } else {
            print("RESULT: FAIL — \(failures) case(s) wrong")
            exit(1)
        }
    }
}
