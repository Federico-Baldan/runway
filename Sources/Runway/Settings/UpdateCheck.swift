import AppKit

/// Checks GitHub for a newer release.
///
/// Read-only and opt-in: it never downloads or installs anything, it just
/// notices that a newer tag exists and points at the release page. Homebrew
/// does the actual upgrading.
@MainActor
enum UpdateCheck {
    /// The repository Runway itself lives in. Rewritten by `scripts/release.sh`
    /// if the project is forked under another owner.
    static let repository = "Federico-Baldan/runway"

    private static var releasesURL: URL? {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
    }

    private static var pageURL: URL? {
        URL(string: "https://github.com/\(repository)/releases/latest")
    }

    private static let lastCheckKey = "update.lastCheck"
    private static let latestSeenKey = "update.latestSeen"

    /// Newest version seen on GitHub, when it is newer than this build.
    private(set) static var availableVersion: String?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Check at most once a day, in the background, failing silently.
    ///
    /// The completion fires on both paths — after the network call, and
    /// immediately when the daily check is not due — so the caller never has to
    /// poll to find out whether an update turned up.
    static func checkIfDue(completion: (@MainActor (String?) -> Void)? = nil) {
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 86_400 else {
            // Surface a previously-seen update without hitting the network.
            if let seen = defaults.string(forKey: latestSeenKey), isNewer(seen, than: currentVersion) {
                availableVersion = seen
            }
            completion?(availableVersion)
            return
        }
        defaults.set(Date(), forKey: lastCheckKey)
        check(completion: completion)
    }

    /// Force a check now, ignoring the daily interval.
    static func check(completion: (@MainActor (String?) -> Void)? = nil) {
        guard let releasesURL else { completion?(nil); return }

        var request = URLRequest(url: releasesURL)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(GitHubClient.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Runway", forHTTPHeaderField: "User-Agent")

        // Not `URLSession.shared`: it carries the shared on-disk `URLCache`,
        // and this is a once-a-day request whose answer is already remembered
        // in `latestSeenKey`. See `GitHubClient.sharedSession`.
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: request) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                Task { @MainActor in completion?(nil) }
                return
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            Task { @MainActor in
                UserDefaults.standard.set(version, forKey: latestSeenKey)
                availableVersion = isNewer(version, than: currentVersion) ? version : nil
                completion?(availableVersion)
            }
        }
        task.resume()
        // Releases the session's queue once this one task is done. A session
        // that is never invalidated keeps its worker alive for the life of the
        // process, which for a check that runs once a day is all cost.
        session.finishTasksAndInvalidate()
    }

    static func openReleasePage() {
        guard let pageURL else { return }
        NSWorkspace.shared.open(pageURL)
    }

    /// Semantic-ish comparison, component by component, missing components
    /// read as zero.
    ///
    /// The padding is what stops a phantom update. This used to require exactly
    /// three numeric components on **both** sides and otherwise fall back to
    /// `candidate != current` — so a release tagged `v0.7` against an installed
    /// `0.7.0` compared unequal, was called newer, and put "Update available:
    /// 0.7" in the menu bar of a machine already running it, permanently: the
    /// check is once a day and the answer never changes.
    ///
    /// `compactMap` was the other half of it. It *drops* a component it cannot
    /// read rather than failing, so `1.10.0-rc1` parsed to `[1, 10]` — a
    /// two-component version, straight into the same fallback. A pre-release
    /// suffix now makes the whole comparison decline instead, which is the
    /// honest answer: Runway ships plain `MAJOR.MINOR.PATCH` tags, and a tag
    /// that is not one is not a release this can reason about.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = components(of: candidate), let b = components(of: current) else {
            return false
        }
        for index in 0..<max(a.count, b.count) {
            let lhs = index < a.count ? a[index] : 0
            let rhs = index < b.count ? b[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    /// A dotted version as numbers, or `nil` if any part of it is not one.
    private static func components(of version: String) -> [Int]? {
        let parts = version.split(separator: ".")
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        numbers.reserveCapacity(parts.count)
        for part in parts {
            guard let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        return numbers
    }
}
