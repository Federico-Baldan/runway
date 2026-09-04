import AppKit

/// Prints everything that determines where — and whether — the island appears.
///
/// Exists because "the island didn't show up" has several unrelated causes with
/// no way to tell them apart from a screenshot: wrong display picked, notch not
/// detected, nothing actually running, the actor filter hiding everything, or
/// the resting state simply being too subtle to notice against a black bezel.
///
/// Run with: `Runway --diagnose`
@MainActor
enum Diagnostics {
    static func run() {
        print("Runway — diagnostics")
        print(String(repeating: "=", count: 52))
        print()

        displays()
        placement()
        filters()
        notifications()
        account()
    }

    private static func displays() {
        let screens = NSScreen.screens
        let active = NotchGeometry.activeScreen()
        let pinned = Preferences.shared.pinnedDisplay
        print("displays attached: \(screens.count)")
        for (index, screen) in screens.enumerated() {
            let isMain = screen == NSScreen.main
            let isActive = screen == active
            let notch = screen.safeAreaInsets.top
            print("  [\(index)] \(screen.localizedName)")
            print("       size          \(Int(screen.frame.width))x\(Int(screen.frame.height)) at \(Int(screen.frame.origin.x)),\(Int(screen.frame.origin.y))")
            print("       scale         \(screen.backingScaleFactor)x")
            print("       safeAreaTop   \(notch)  \(notch > 0 ? "<- HAS A NOTCH" : "(no notch)")")
            print("       menu bar      \(screen.frame.origin == .zero ? "yes" : "no")")
            print("       keyboard focus\(isMain ? " yes" : " no")")
            print("       pointer is here\(isActive ? " yes" : " no")")
            if let id = NotchGeometry.displayID(of: screen) {
                print("       display id    \(id)\(Int(id) == pinned ? "  <- PINNED" : "")")
            }
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                let cutout = screen.frame.width - left.width - right.width
                print("       cutout width  \(Int(cutout))pt")
            } else {
                print("       cutout width  n/a (auxiliary areas are nil)")
            }
        }
        print()
    }

    private static func placement() {
        let preference = Preferences.shared.screenPreference
        print("screen preference: \(preference.rawValue)")
        if preference == .pinned {
            let pinned = Preferences.shared.pinnedDisplay
            print("  pinned display: \(pinned == 0 ? "none set" : String(pinned))")
        }
        guard let chosen = NotchGeometry.screen(for: preference) else {
            print("  !! no screen resolved — the island cannot be placed")
            print()
            return
        }
        print("  resolves to: \(chosen.localizedName)")

        let canvas = NotchGeometry.canvasSize(for: chosen, rows: 1)
        let placement = NotchGeometry.placement(on: chosen, size: canvas)
        print("  panel frame: \(Int(placement.frame.width))x\(Int(placement.frame.height))"
            + " at \(Int(placement.frame.origin.x)),\(Int(placement.frame.origin.y))")
        print("  hasNotch:    \(placement.hasNotch)")
        print("  notch size:  \(Int(placement.notchWidth))x\(Int(placement.notchHeight))")

        let restingWidth = NotchGeometry.Width.resting(
            hasNotch: placement.hasNotch,
            notchWidth: placement.notchWidth
        )
        print("  resting width: \(Int(restingWidth))pt")
        if placement.hasNotch {
            print("  On a notched Mac the RESTING island is the cutout's width plus a")
            print("  concave shoulder either side, so it blends into the housing instead")
            print("  of hanging off it: a small status dot on black, sitting on the black")
            print("  bezel. Deliberately subtle and easy to miss. Hover the notch to expand.")
        } else {
            print("  On a display without a notch the island is a \(Int(restingWidth))pt pill")
            print("  centred under the menu bar.")
        }

        // "Nothing is in my notch" and "something is in my notch" are both
        // questions this tool now has to answer.
        let idleMark = Preferences.shared.idleMark
        print("  idle mark:   \(idleMark ? "on" : "off")"
            + (placement.hasNotch ? "" : "  (notched displays only — not this one)"))
        if idleMark, placement.hasNotch {
            print("  So with nothing running the island does not leave: it stays as a few")
            print("  points of black under the cutout with the mark in it, blinking and")
            print("  looking around. That is the dot you are looking at.")
            print("  position:    \(Preferences.shared.idleMarkPosition.rawValue)")
            print("  colour:      \(Preferences.shared.idleMarkTint.rawValue)")
        }
        print()
    }

    /// The half of "nothing is showing up" that is a filter, not a display.
    private static func filters() {
        let preferences = Preferences.shared
        print("repositories: \(preferences.repoScope.rawValue) (limit \(preferences.repoLimit))")
        if preferences.repoScope == .organizations {
            let orgs = preferences.organizations.sorted().joined(separator: ", ")
            print("  organizations: \(orgs.isEmpty ? "NONE SELECTED — nothing will be polled" : orgs)")
        }
        if preferences.repoScope == .explicit {
            let repos = preferences.explicitRepositories.joined(separator: ", ")
            print("  list: \(repos.isEmpty ? "EMPTY — nothing will be polled" : repos)")
        }

        print("whose runs: \(preferences.actorScope.rawValue)")
        if preferences.actorScope == .list {
            print("  watching: \(preferences.watchedActors.joined(separator: ", "))")
        }
        let filter = preferences.actorFilter
        if filter.isEveryone {
            print("  resolves to: everyone (no actor filter applied)")
        } else {
            print("  resolves to: \(filter.logins.sorted().joined(separator: ", "))")
            print("  filtered locally from the 30 most recent runs per repository")
            print("  (GitHub's ?actor= is not used: it matches the push author, so it")
            print("   cannot see a run somebody else pushed and you re-ran)")
            if preferences.approvalsFromOthers {
                print("  + deploys waiting on YOUR approval are let through the filter")
                print("    (inside an org a reviewing team makes that most of them)")
            } else {
                print("  + nothing else, others' deploys awaiting your approval included")
            }
        }
        if preferences.currentUser == nil {
            print("  !! login not resolved yet, so @me matches nothing until the token is verified")
        }
        print()

        let set = EnvironmentDefault.all.filter { EnvironmentDefault.isSet($0) }
        if set.isEmpty {
            print("environment defaults: none set")
        } else {
            print("environment defaults set (these seed a setting you have never")
            print("changed; anything you pick in Settings wins from then on):")
            for name in set {
                print("  \(name)=\(EnvironmentDefault.string(name) ?? "")")
            }
            print("  the values in force are the ones printed above, not necessarily these")
        }
        print()
    }

    /// The other half of "it never told me": whether a banner could even be
    /// delivered, and the rule that decides whether one is sent at all.
    private static func notifications() {
        print("approval banners: \(Preferences.shared.approvalNotifications ? "on" : "off")")
        if let identifier = Bundle.main.bundleIdentifier {
            print("  bundle: \(identifier)")
            print("  the system's own answer is in System Settings > Notifications > Runway")
        } else {
            print("  !! running as a bare executable, not an app bundle — macOS has")
            print("     nothing to attach a notification permission to. Banners work")
            print("     from the installed Runway.app; `make demo` cannot show one.")
        }
        print("  Runway notifies ONLY when GitHub says this account can approve the")
        print("  deployment (current_user_can_approve on /pending_deployments). A")
        print("  colleague's deploy reaching production is drawn on the island in")
        print("  amber and never sent to Notification Centre.")
        print()
    }

    private static func account() {
        let hasToken = TokenCache.shared.token() != nil
        print("token in keychain: \(hasToken ? "yes" : "NO — nothing will ever appear")")
        print("api base: \(GitHubClient.baseURL(for: Preferences.shared.host).absoluteString)")
        print("api version: \(GitHubClient.apiVersion)")
        print()
        print("Note: the island only appears while a run is IN PROGRESS, or")
        print("briefly after one finishes. If nothing is running, an empty")
        print("notch is correct behaviour — check the menu bar icon instead.")
    }
}
