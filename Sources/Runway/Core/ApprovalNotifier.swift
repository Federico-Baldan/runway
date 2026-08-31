import AppKit
import Foundation
import UserNotifications

/// Notification Centre banners for the one thing in CI that is genuinely
/// waiting on *you*.
///
/// Runway is otherwise a glanceable app: the island appears, you look at it,
/// it goes away. An approval is the exception. A deploy parked on a required
/// reviewer does not fail, does not retry, and does not go anywhere for thirty
/// days — after which GitHub cancels it. It is the only state where not
/// looking at the screen has a cost, so it is the only state that interrupts.
///
/// The rule, and the whole reason `ApprovalCheck` exists: **notify only when
/// GitHub says this account can approve it.** `current_user_can_approve` is a
/// field in the API for exactly this purpose. A colleague's deploy reaching
/// production is worth drawing on the island and worth nothing in Notification
/// Centre, and an app that gets that wrong in a fifty-person organization is an
/// app you turn off in a week.
@MainActor
public enum ApprovalNotifier {
    /// Mirrored from `Preferences.approvalNotifications`.
    public static var isEnabled = true

    /// Key the run's URL travels under, so a click can open it.
    static let urlKey = "runway.url"

    /// What Notification Centre currently allows.
    public enum Authorization: Equatable, Sendable {
        /// Not asked yet.
        case notDetermined
        case authorized
        case denied
        /// Cannot ask: the process has no bundle, so there is nothing for
        /// macOS to grant a permission *to*.
        case unavailable(String)

        public var isUsable: Bool { self == .authorized }

        public var label: String {
            switch self {
            case .notDetermined: return "Not asked yet — Runway will ask when an approval first needs you."
            case .authorized: return "Allowed. Banners appear when a deployment is waiting on your approval."
            case .denied: return "Turned off in System Settings → Notifications → Runway."
            case .unavailable(let reason): return reason
            }
        }
    }

    public private(set) static var authorization: Authorization = .notDetermined

    /// Runs already announced, so a poll every five seconds does not announce
    /// the same approval twelve times a minute.
    ///
    /// Persisted rather than held in memory: an approval sits there for days,
    /// and an app relaunched each morning would otherwise re-announce every one
    /// of them. The list is capped and pruned to what is still on screen.
    private static var announced: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: announcedKey) ?? []
    )
    private static let announcedKey = "approvals.announced"
    private static let announcedLimit = 200

    /// Held for the life of the process: `UNUserNotificationCenter.delegate` is
    /// weak, and a delegate that has been deallocated makes a click on the
    /// banner do nothing at all.
    private static let clickHandler = NotificationClickHandler()
    private static var isPrepared = false

    // MARK: - Availability

    /// Whether this process can post a notification at all.
    ///
    /// `UNUserNotificationCenter.current()` **traps** — it does not throw or
    /// return nil — in a process with no bundle identifier, which is exactly
    /// what `make demo`, `make snapshot` and the spikes run: the bare
    /// executable out of `.build`. Every call below goes through this.
    private static var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else {
            authorization = .unavailable(
                "Runway is running as a bare executable, not an app bundle — "
                + "macOS has nothing to attach a notification permission to. "
                + "Banners work from the installed app."
            )
            return nil
        }
        return UNUserNotificationCenter.current()
    }

    /// Install the click handler and read the current permission.
    ///
    /// Deliberately does **not** ask for permission. A CI app that throws a
    /// system prompt at you thirty seconds after first launch, before it has
    /// ever had anything to say, gets denied — and a denial is far harder to
    /// walk back than a question asked at the right moment. Runway asks the
    /// first time something is actually waiting on you.
    public static func prepare() {
        guard !isPrepared, let center else { return }
        isPrepared = true
        center.delegate = clickHandler
        refreshAuthorization()
    }

    /// Re-read the system's answer, for Settings.
    public static func refreshAuthorization() {
        guard let center else { return }
        center.getNotificationSettings { settings in
            // Read the one Sendable value out here; `UNNotificationSettings`
            // itself must not cross into the main actor.
            let status = settings.authorizationStatus
            Task { @MainActor in
                authorization = Self.map(status)
            }
        }
    }

    /// `default` rather than an exhaustive list on purpose: `provisional` and
    /// `ephemeral` both mean "you may post", and only one of them exists on
    /// every platform this has to compile for.
    private static func map(_ status: UNAuthorizationStatus) -> Authorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .authorized
        }
    }

    /// Ask, once, and run `then` with the answer.
    ///
    /// `@Sendable` on the callback is not decoration: it is handed to a
    /// completion block that macOS calls from its own queue, and Swift 6 will
    /// not let a plain closure make that crossing.
    public static func requestAuthorization(then: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        guard let center else {
            then?(false)
            return
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            // `any Error` is not Sendable, so the message is flattened to a
            // string before anything hops actors.
            let failure = error?.localizedDescription
            Task { @MainActor in
                authorization = granted
                    ? .authorized
                    : (failure.map { .unavailable($0) } ?? .denied)
                then?(granted)
            }
        }
    }

    // MARK: - The check

    /// Called on every monitor update, from `IslandModel.apply`.
    public static func runsChanged(_ runs: [WorkflowRun]) {
        // Forget runs that have moved on, so the same run blocking again later
        // — a re-run, a second environment — is announced again.
        let blocked = Set(runs.filter(\.isBlockedOnApproval).map(\.identity))
        let live = Set(runs.map(\.identity))
        let stale = announced.filter { key in
            guard let identity = key.split(separator: "|").first.map(String.init) else { return true }
            // Keep the record while the run is still blocked; drop it once the
            // run has been approved, finished, or scrolled out of the window.
            return !blocked.contains(identity) && live.contains(identity)
        }
        if !stale.isEmpty {
            announced.subtract(stale)
            persistAnnounced()
        }

        guard isEnabled else { return }

        for run in runs {
            guard case .needsMe(let environments) = run.approval else { continue }
            let key = "\(run.identity)|\(environments.sorted().joined(separator: ","))"
            guard !announced.contains(key) else { continue }
            announced.insert(key)
            persistAnnounced()
            post(for: run, environments: environments)
        }
    }

    /// Forget everything. Runs on a token change: a different account has a
    /// different idea of what is waiting on it.
    public static func resetBaseline() {
        announced.removeAll()
        persistAnnounced()
    }

    private static func persistAnnounced() {
        if announced.count > announcedLimit {
            announced = Set(announced.sorted().suffix(announcedLimit))
        }
        UserDefaults.standard.set(Array(announced).sorted(), forKey: announcedKey)
    }

    // MARK: - Posting

    private static func post(for run: WorkflowRun, environments: [String]) {
        guard let center else { return }

        switch authorization {
        case .authorized:
            deliver(for: run, environments: environments, through: center)
        case .notDetermined:
            // The right moment to ask: something is genuinely waiting on this
            // person, so the prompt has an answer to give.
            requestAuthorization { granted in
                guard granted, let center = Self.center else { return }
                Self.deliver(for: run, environments: environments, through: center)
            }
        case .denied, .unavailable:
            // The island still shows it in amber; that is the fallback, and it
            // is why the notification is an addition rather than the feature.
            break
        }
    }

    private static func deliver(
        for run: WorkflowRun,
        environments: [String],
        through center: UNUserNotificationCenter
    ) {
        let content = UNMutableNotificationContent()
        content.title = environments.count == 1
            ? "Approve \(environments[0])?"
            : "A deployment needs your approval"
        content.subtitle = "\(run.repository) #\(run.runNumber)"

        var lines: [String] = []
        if let branch = run.headBranch { lines.append(branch) }
        if let login = run.triggeringActor?.login ?? run.actor?.login { lines.append("by \(login)") }
        if environments.count > 1 { lines.append(environments.joined(separator: ", ")) }
        content.body = lines.isEmpty
            ? "Open the run on GitHub to approve it."
            : lines.joined(separator: " · ") + " — open the run on GitHub to approve it."

        content.sound = .default
        // Group repeats from the same run instead of stacking them.
        content.threadIdentifier = run.identity
        if let url = run.webURL()?.absoluteString {
            content.userInfo = [urlKey: url]
        }

        // `nil` trigger means deliver immediately.
        let request = UNNotificationRequest(
            identifier: "approval:\(run.identity)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    /// Post a sample banner, for the button in Settings.
    public static func demo() {
        guard let center else { return }
        guard authorization == .authorized else {
            requestAuthorization { granted in if granted { Self.demo() } }
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Approve production?"
        content.subtitle = "acme/web-app #562"
        content.body = "main · by you — open the run on GitHub to approve it."
        content.sound = .default
        center.add(UNNotificationRequest(
            identifier: "approval:demo:\(UUID().uuidString)",
            content: content,
            trigger: nil
        ))
    }

    /// Send the user to the right pane when they have denied us.
    public static func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.notifications"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Opens the run when its banner is clicked.
///
/// Not `@MainActor`: the system calls a notification delegate from its own
/// context, and the only thing that has to happen on the main actor is the
/// `NSWorkspace` call at the end.
private final class NotificationClickHandler: NSObject, UNUserNotificationCenterDelegate {
    /// Show the banner even while Runway is the frontmost app. The default is
    /// to swallow it, which for a menu bar app means the one moment you have
    /// Settings open is the one moment you are not told.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let link = response.notification.request.content.userInfo[ApprovalNotifier.urlKey] as? String
        guard let link, let url = URL(string: link) else { return }
        await MainActor.run { NSWorkspace.shared.open(url) }
    }
}
