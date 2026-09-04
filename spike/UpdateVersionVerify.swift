// Is a tag actually newer than the build that is running?
//
// This comparison has been wrong twice, and both times the symptom was the
// same and permanent: "Update available: 0.7" pinned in the menu bar of a
// machine already running 0.7.0, because the check runs once a day and the
// answer never changes. It is worth having assertions on for the same reason
// `NotchMath` has them — the failure is silent, it is on somebody else's
// machine, and nothing about reading the code tells you it is happening.
//
// The two it has to keep passing:
//
//  * A release tagged `v0.7` against an installed `0.7.0`. Requiring exactly
//    three components on both sides and otherwise falling back to
//    `candidate != current` made those compare unequal, and unequal was read
//    as newer.
//  * `1.10.0-rc1`. `compactMap` *drops* a component it cannot read rather than
//    failing, so that parsed to `[1, 10]` — a two-component version, straight
//    back into the same fallback.
//
// NOT wired into `make spikes-offline`. `UpdateCheck.swift` imports AppKit and
// reaches `GitHubClient.apiVersion`, so the SRC list is the monitor stack plus
// this file, and that has not been checked against a Mac. Run it by hand, or
// wire it once the list is known good:
//
//   swiftc -o /tmp/updateversion spike/UpdateVersionVerify.swift \
//       Sources/Runway/Settings/UpdateCheck.swift \
//       Sources/Runway/API/GitHubClient.swift Sources/Runway/API/Models.swift \
//       Sources/Runway/API/Approvals.swift Sources/Runway/API/DeployTarget.swift \
//       Sources/Runway/API/RunScope.swift Sources/Runway/API/ETagStore.swift \
//       Sources/Runway/Auth/Keychain.swift && /tmp/updateversion

import Foundation

@main
enum UpdateVersionVerify {
    @MainActor
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

        let newer = UpdateCheck.isNewer

        print("── the ordinary direction ──")
        assert("0.9.0 is newer than 0.8.0", newer("0.9.0", "0.8.0"))
        assert("0.8.0 is not newer than 0.9.0", !newer("0.8.0", "0.9.0"))
        assert("and a build is never newer than itself", !newer("0.8.0", "0.8.0"))

        print()
        print("── the phantom update: a two-component tag ──")
        assert("v0.7 is NOT newer than an installed 0.7.0", !newer("0.7", "0.7.0"))
        assert("nor the other way round", !newer("0.7.0", "0.7"))
        assert("but 0.7.1 still is", newer("0.7.1", "0.7"))

        print()
        print("── numeric, not lexicographic ──")
        // "0.10.0" < "0.9.0" as strings, and this is exactly the release where
        // a string comparison would start lying and never stop.
        assert("0.10.0 is newer than 0.9.0", newer("0.10.0", "0.9.0"))
        assert("1.10.0 is newer than 1.9.9", newer("1.10.0", "1.9.9"))

        print()
        print("── a tag that is not a release declines rather than guesses ──")
        assert("a pre-release suffix is not read as newer", !newer("1.10.0-rc1", "1.9.0"))
        assert("nor is a bare word", !newer("nightly", "0.8.0"))
        assert("nor an empty tag", !newer("", "0.8.0"))
        // `currentVersion` falls back to "0.0.0" outside a bundle, but Info.plist
        // is editable and a garbled one must not make every tag look newer.
        assert("an unreadable CURRENT version declines too", !newer("1.0.0", "dev"))
        assert("and a negative component is not a version", !newer("1.-2.0", "0.1.0"))

        print()
        if failures == 0 {
            print("RESULT: PASS — only a real release reads as one")
        } else {
            print("RESULT: FAIL — \(failures) comparison(s) wrong")
            exit(1)
        }
    }
}
