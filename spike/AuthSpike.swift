// Does the stored token actually work, and what is it allowed to see?
//
// A live check, so it needs a token in the keychain. The value is that "the
// island is empty" and "the token cannot read Actions" look identical from the
// outside, and a fine-grained token scoped to the wrong repositories is the
// most common way to get the second one.
//
//   swiftc -o /tmp/authspike spike/AuthSpike.swift \
//       Sources/Runway/API/GitHubClient.swift Sources/Runway/API/Models.swift \
//       Sources/Runway/API/RunScope.swift Sources/Runway/API/ETagStore.swift \
//       Sources/Runway/Auth/Keychain.swift && /tmp/authspike check

import Foundation

@main
enum AuthSpike {
    static func main() {
        let arguments = CommandLine.arguments
        let command = arguments.count > 1 ? arguments[1] : "check"

        func fail(_ message: String) -> Never {
            print("FAIL: \(message)")
            exit(1)
        }

        switch command {
        case "store":
            guard arguments.count > 2 else { fail("usage: AuthSpike store <TOKEN>") }
            do {
                try Keychain.store(arguments[2])
                print("stored in \(Keychain.service)/\(Keychain.account)")
                if let kind = Keychain.describe(arguments[2]) { print("looks like a \(kind)") }
            } catch {
                fail(error.localizedDescription)
            }

        case "check":
            guard let token = TokenCache.shared.token(), !token.isEmpty else {
                fail("no token in the keychain. Run: AuthSpike store <TOKEN>")
            }
            print("token found (\(Keychain.describe(token) ?? "unrecognised shape"))")

            let semaphore = DispatchSemaphore(value: 0)
            var exitCode: Int32 = 0

            Task {
                let client = GitHubClient()
                do {
                    let user = try await client.fetchAuthenticatedUser()
                    print("authenticated as \(user.login)")

                    let repositories = try await client.fetchRepositories(
                        scope: .recent, limit: 5, organizations: [], explicit: []
                    )
                    print("\(repositories.count) repositories visible, by recent push:")
                    for repository in repositories {
                        print("  \(repository.fullName)\(repository.isPrivate ? "  (private)" : "")")
                    }

                    guard let first = repositories.first else {
                        print()
                        print("WARNING: the token can see no repositories at all.")
                        print("A fine-grained token must have the repositories explicitly selected.")
                        exitCode = 1
                        semaphore.signal()
                        return
                    }

                    // The permission that actually matters. A token with Contents but
                    // not Actions authenticates fine and then 403s here — which is the
                    // failure this spike exists to name.
                    let response = try await client.fetchRuns(repository: first.fullName, perPage: 3)
                    print()
                    print("Actions readable on \(first.fullName): \(response.value.totalCount) runs total")

                    // Prove the conditional cache works: the second identical request
                    // must come back 304, or the rate-limit maths in the README is a lie.
                    let again = try await client.fetchRuns(repository: first.fullName, perPage: 3)
                    print("second identical request: \(again.notModified ? "304 Not Modified (free)" : "200 — NOT cached")")
                    if !again.notModified {
                        print("WARNING: no ETag reuse. Polling will burn the rate limit.")
                        exitCode = 1
                    }

                    let rate = await client.currentRateLimit()
                    print()
                    print("rate limit: \(rate.remaining)/\(rate.limit), resets in \(rate.resetDescription)")
                    print("billed \(rate.billedRequests), free \(rate.savedRequests)")
                } catch let error as GitHubError {
                    print("FAILED: \(error.errorDescription ?? "unknown")")
                    if case .forbidden = error {
                        print()
                        print("A 403 here usually means the token lacks Actions: Read.")
                        print("Fine-grained tokens need it granted per repository.")
                    }
                    exitCode = 1
                } catch {
                    print("FAILED: \(error.localizedDescription)")
                    exitCode = 1
                }
                semaphore.signal()
            }

            semaphore.wait()
            print()
            print(exitCode == 0 ? "RESULT: PASS — token works and Actions are readable"
                                : "RESULT: FAIL")
            exit(exitCode)

        case "delete":
            try? Keychain.delete()
            print("token deleted")

        default:
            print("usage: AuthSpike [check | store <TOKEN> | delete]")
            exit(1)
        }
    }
}
