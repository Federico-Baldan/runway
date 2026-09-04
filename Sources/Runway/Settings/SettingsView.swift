import AppKit
import SwiftUI

/// Settings window.
@MainActor
public final class SettingsWindowController {
    private var window: NSWindow?
    private let model: IslandModel
    private let onTokenChanged: () -> Void
    private let onRestoreDismissed: () -> Void

    public init(
        model: IslandModel,
        onTokenChanged: @escaping () -> Void,
        onRestoreDismissed: @escaping () -> Void = {}
    ) {
        self.model = model
        self.onTokenChanged = onTokenChanged
        self.onRestoreDismissed = onRestoreDismissed
    }

    public func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = SettingsView(
            model: model,
            onTokenChanged: onTokenChanged,
            onRestoreDismissed: onRestoreDismissed,
            onClose: { [weak self] in self?.close() }
        )

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Runway Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 620))
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    public func close() {
        window?.close()
    }
}

/// The settings pane itself.
struct SettingsView: View {
    @Bindable var model: IslandModel
    let onTokenChanged: () -> Void
    var onRestoreDismissed: () -> Void = {}
    let onClose: () -> Void

    @State private var preferences = Preferences.shared
    @State private var tokenField = ""
    @State private var tokenStatus: TokenStatus = .unknown
    @State private var isVerifying = false
    @State private var organizations: [Organization] = []
    @State private var isLoadingOrganizations = false
    /// Why the organization list is empty or short. Both used to be invisible.
    @State private var organizationError: String?
    @State private var organizationSSO: SSONotice?
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    @State private var newActor = ""
    @State private var actorError: String?
    @State private var newRepository = ""
    /// Runs the user has taken off the island by hand. Read once when the pane
    /// appears rather than on every body pass — it is a `UserDefaults` lookup
    /// and it only changes from the island, which is not on screen behind this
    /// window.
    @State private var dismissedCount = 0

    enum TokenStatus: Equatable {
        case unknown
        case stored(login: String)
        case missing
        case invalid(String)

        var colour: Color {
            switch self {
            case .stored: return .green
            case .invalid: return .red
            case .missing: return .orange
            case .unknown: return .secondary
            }
        }

        var label: String {
            switch self {
            case .unknown: return "Not checked"
            case .stored(let login): return "Connected as \(login)"
            case .missing: return "No token stored"
            case .invalid(let message): return message
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    account
                    Divider()
                    whoseRuns
                    Divider()
                    whichRepositories
                    Divider()
                    alerts
                    Divider()
                    display
                }
                .padding(20)
            }

            Divider()

            HStack {
                Text("Runway \(Bundle.main.shortVersion)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 520, minHeight: 620)
        .onAppear {
            checkToken()
            launchAtLogin = LaunchAtLogin.isEnabled
            ApprovalNotifier.prepare()
            ApprovalNotifier.refreshAuthorization()
        }
    }

    // MARK: - Whose runs

    /// The actor filter. First section on purpose: on a shared organization it
    /// is the setting that decides whether the island is useful or unreadable.
    private var whoseRuns: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Whose runs")
                    .font(.headline)
                Spacer()
                overrideBadge(EnvironmentDefault.actorMode)
            }

            ForEach(ActorScope.allCases, id: \.self) { option in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: preferences.actorScope == option
                          ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(preferences.actorScope == option
                                         ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(option.label)
                            .font(.system(size: 12, weight: .medium))
                        Text(option.detail)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if let count = runCount(for: option) {
                        Text("\(count)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .help("Runs currently visible with this option")
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { preferences.actorScope = option }
            }

            if preferences.actorScope == .list {
                actorList
                    .padding(.leading, 24)
                    .padding(.top, 4)
            }

            // Only meaningful while something is being filtered out.
            if preferences.actorScope != .everyone {
                Divider().padding(.vertical, 2)
                HStack(alignment: .top) {
                    Toggle(isOn: $preferences.approvalsFromOthers) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Let deploys waiting on my approval through anyway")
                                .font(.system(size: 12, weight: .medium))
                            markdown("Off, so the choice above is absolute. On, a colleague's "
                                     + "deploy joins the island when GitHub says **you** can "
                                     + "approve it. Inside an organization that is usually "
                                     + "every deploy: if you are in a reviewing team, GitHub "
                                     + "names you on everybody's.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    Spacer(minLength: 6)
                    overrideBadge(EnvironmentDefault.approvalsFromOthers)
                }
            }
        }
    }

    /// The watch list itself: chips, an add field, and suggestions from live data.
    private var actorList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if preferences.watchedActors.isEmpty {
                Text("Nobody listed — every run is shown until you add someone.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(preferences.watchedActors, id: \.self) { login in
                    actorToken(login)
                }
            }

            HStack(spacing: 6) {
                TextField("GitHub username, or @me", text: $newActor)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addActor() }
                Button("Add") { addActor() }
                    .disabled(newActor.trimmingCharacters(in: .whitespaces).isEmpty)
                overrideBadge(EnvironmentDefault.actors)
            }
            .controlSize(.small)

            if let actorError {
                Text(actorError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // Anyone whose runs came back in the last poll but is not watched —
            // the cheapest possible discovery, with no extra API call.
            let suggestions = model.state.knownActors.filter { login in
                !preferences.watchedActors.contains {
                    $0.caseInsensitiveCompare(login) == .orderedSame
                } && login.caseInsensitiveCompare(preferences.currentUser ?? "") != .orderedSame
            }
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Seen recently")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(suggestions.prefix(8), id: \.self) { login in
                            Button {
                                preferences.watchActor(login)
                            } label: {
                                Label(login, systemImage: "plus")
                                    .font(.system(size: 10, design: .monospaced))
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(Color.secondary.opacity(0.12))
                            )
                        }
                    }
                }
            }

            Text(filterExplanation)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func actorToken(_ login: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: login.caseInsensitiveCompare(ActorFilter.selfToken) == .orderedSame
                  ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                .font(.system(size: 10))
            Text(login)
                .font(.system(size: 11, design: .monospaced))
            Button {
                preferences.unwatchActor(login)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.accentColor.opacity(0.16)))
        .help(login.caseInsensitiveCompare(ActorFilter.selfToken) == .orderedSame
              ? "Resolves to \(preferences.currentUser ?? "your login") once the token is verified"
              : login)
    }

    /// Say who is actually being watched, and name the one real limitation.
    private var filterExplanation: String {
        let filter = preferences.actorFilter
        if filter.isEveryone {
            return "No filter is applied — every run in the watched repositories will show."
        }
        let names = filter.logins.sorted().joined(separator: ", ")
        let approvals = preferences.approvalsFromOthers
            ? " Deploys waiting on your approval are let through as well, whoever pushed them."
            : " Nothing else is shown, a colleague's deploy waiting on your approval included."
        return "Watching \(names). Runway reads the 30 most recent runs per repository and "
            + "keeps the ones these people pushed or re-ran. GitHub's own ?actor= filter is not "
            + "used: it matches the push author, so it cannot see a run you re-ran for someone "
            + "else." + approvals
    }

    private func addActor() {
        let trimmed = newActor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        actorError = nil

        // `@me` needs no lookup, and is valid before the token is even verified.
        if trimmed.caseInsensitiveCompare(ActorFilter.selfToken) == .orderedSame {
            preferences.watchActor(ActorFilter.selfToken)
            newActor = ""
            return
        }

        // Confirm the login exists rather than silently watching a typo that
        // would just show nothing forever.
        let login = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
        guard TokenCache.shared.token() != nil else {
            preferences.watchActor(login)
            newActor = ""
            return
        }
        Task {
            let client = GitHubClient(baseURL: GitHubClient.baseURL(for: preferences.host))
            do {
                let user = try await client.fetchUser(login: login)
                await MainActor.run {
                    preferences.watchActor(user.login)
                    newActor = ""
                    actorError = nil
                }
            } catch {
                await MainActor.run {
                    actorError = "No GitHub user called \"\(login)\"."
                }
            }
        }
    }

    /// Live count of runs each actor scope would show.
    ///
    /// Counted from `unfilteredRuns`, because `runs` has already been through
    /// whichever option is selected right now — so filtering it again could
    /// only ever subtract. Previewing "Everyone" from "Only my runs" counted my
    /// runs and printed that beside both options, which is precisely the
    /// comparison this number is here to make.
    private func runCount(for option: ActorScope) -> Int? {
        let runs = model.state.unfilteredRuns
        guard !runs.isEmpty else { return nil }
        let filter = ActorFilter.resolve(
            scope: option,
            watched: preferences.watchedActors,
            currentUser: preferences.currentUser
        )
        return filter.apply(runs).count
    }

    // MARK: - Which repositories

    private var whichRepositories: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Which repositories")
                    .font(.headline)
                Spacer()
                overrideBadge(EnvironmentDefault.repoScope)
            }

            Text("GitHub has no endpoint for \"every run I can see\", so Runway polls a "
                 + "repository at a time. Fewer repositories means a faster island and a "
                 + "smaller share of your API budget.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(RepoScope.allCases, id: \.self) { option in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: preferences.repoScope == option
                          ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(preferences.repoScope == option
                                         ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(option.label)
                            .font(.system(size: 12, weight: .medium))
                        Text(option.detail)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    preferences.repoScope = option
                    if option == .organizations { loadOrganizations() }
                }
            }

            if preferences.repoScope == .organizations {
                organizationPicker
                    .padding(.leading, 24)
            }

            if preferences.repoScope == .explicit {
                explicitRepositoryList
                    .padding(.leading, 24)
            }

            if preferences.repoScope != .explicit {
                Divider().padding(.vertical, 4)
                HStack(spacing: 8) {
                    Text("Poll at most")
                    Stepper(
                        value: $preferences.repoLimit,
                        in: 1...100,
                        step: 5
                    ) {
                        Text("\(preferences.repoLimit) repositories")
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
                .font(.system(size: 12))

                Text(budgetEstimate)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.state.repositories.isEmpty {
                Text("Currently watching: "
                     + model.state.repositories.prefix(6).joined(separator: ", ")
                     + (model.state.repositories.count > 6
                        ? " +\(model.state.repositories.count - 6) more" : ""))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Say what the current settings cost, in the units GitHub bills in.
    private var budgetEstimate: String {
        let rate = model.state.rateLimit
        guard rate.limit > 0 else {
            return "Unchanged repositories answer 304 Not Modified, which GitHub does not "
                + "charge against the hourly limit."
        }
        let saved = Int(rate.cacheHitRate * 100)
        return "\(rate.remaining) of \(rate.limit) requests left this hour, resetting in "
            + "\(rate.resetDescription). \(saved)% of polls so far were answered from cache "
            + "and cost nothing."
    }

    private var organizationPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isLoadingOrganizations {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading your organizations…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                if organizations.isEmpty {
                    HStack(spacing: 8) {
                        Text("No organizations came back for this token.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Reload") { loadOrganizations(force: true) }
                            .controlSize(.small)
                    }
                } else {
                    ForEach(organizations) { organization in
                        // Case-insensitively, because GitHub is and
                        // `RUNWAY_ORGS` is taken verbatim. An organization
                        // seeded as `Acme` while the API calls it `acme` was
                        // being watched and drawn unchecked, and ticking the box
                        // added the second spelling rather than replacing the
                        // first — two entries for one organization, and a
                        // request per discovery pass for the privilege.
                        // Removing both before inserting normalises to whatever
                        // GitHub itself calls it.
                        Toggle(isOn: Binding(
                            get: {
                                preferences.organizations.contains {
                                    $0.caseInsensitiveCompare(organization.login) == .orderedSame
                                }
                            },
                            set: { on in
                                var next = preferences.organizations.filter {
                                    $0.caseInsensitiveCompare(organization.login) != .orderedSame
                                }
                                if on { next.insert(organization.login) }
                                preferences.organizations = next
                            }
                        )) {
                            Text(organization.login)
                                .font(.system(size: 11, design: .monospaced))
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                organizationDiagnostic
            }
        }
        .onAppear { loadOrganizations() }
    }

    /// The sentence that used to be missing.
    ///
    /// Ordered by how specific the evidence is: an SSO header names the exact
    /// problem, a thrown error is at least real, and an empty list with
    /// neither is a fine-grained token that was pointed at the wrong owner or
    /// is still waiting on an admin.
    @ViewBuilder
    private var organizationDiagnostic: some View {
        if let notice = organizationSSO {
            switch notice {
            case .partialResults(let ids):
                // The quiet one. HTTP 200, rows missing, no error anywhere.
                organizationNotice(
                    ids.count == 1
                        ? "GitHub left one organization out of this list: this token is not "
                            + "authorized for its SAML single sign-on."
                        : "GitHub left \(ids.count) organizations out of this list: this token "
                            + "is not authorized for their SAML single sign-on.",
                    detail: "Classic tokens need authorizing per organization after they are "
                        + "created — open the token, then Configure SSO → Authorize.",
                    link: ("Open token settings", "https://github.com/settings/tokens")
                )
            case .required(let url):
                organizationNotice(
                    "This organization enforces SAML single sign-on and refused the token.",
                    detail: "One click authorizes it. GitHub's link expires an hour after it "
                        + "was issued, so reload if it has gone stale.",
                    link: ("Authorize on GitHub", url ?? "https://github.com/settings/tokens")
                )
            }
        } else if let organizationError {
            organizationNotice(organizationError, detail: nil, link: nil)
        } else if organizations.isEmpty {
            if isFineGrainedToken {
                // Not a misconfiguration, and nothing the user can fix on the
                // token: GitHub documents /user/orgs as returning "a 200
                // Success response with an empty list" for every fine-grained
                // token, whatever its permissions or resource owner. Which
                // makes this picker unusable with the token type the README
                // recommends — so send them to a scope that does work rather
                // than to a settings page that cannot help.
                organizationNotice(
                    "Fine-grained tokens cannot list organizations. GitHub returns an empty "
                        + "list here for every one of them — this is not something your token "
                        + "is missing.",
                    detail: "Pick \"Recent\" or \"Specific repositories\" above, which read "
                        + "the repository list directly and do work with this token. Choosing "
                        + "organizations by name needs a classic token with the read:org scope.",
                    link: nil
                )
            } else {
                organizationNotice(
                    "The token authenticates, but sees no organizations.",
                    detail: "A classic token needs the read:org scope to list them — without "
                        + "it GitHub refuses the request outright, so an empty list usually "
                        + "means this account is a member of none.",
                    link: ("Open token settings", "https://github.com/settings/tokens")
                )
            }
        }
    }

    /// Whether the stored token is a fine-grained one, by its prefix.
    ///
    /// Worth knowing here because the difference is not a matter of degree:
    /// `/user/orgs` is simply closed to fine-grained tokens, so the same empty
    /// list means two unrelated things depending on which kind is in the
    /// keychain.
    private var isFineGrainedToken: Bool {
        guard let token = TokenCache.shared.token() else { return false }
        return Keychain.kind(of: token) == .fineGrained
    }

    /// One warning row: a headline, the fix, and a way to go do it.
    private func organizationNotice(
        _ message: String,
        detail: String?,
        link: (label: String, url: String)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text(message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let link, let url = URL(string: link.url) {
                HStack(spacing: 8) {
                    Button(link.label) { NSWorkspace.shared.open(url) }
                        .controlSize(.small)
                    Button("Recheck") { loadOrganizations(force: true) }
                        .controlSize(.small)
                }
            }
        }
        .padding(.top, 4)
    }

    private var explicitRepositoryList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(preferences.explicitRepositories, id: \.self) { repository in
                HStack(spacing: 6) {
                    Text(repository)
                        .font(.system(size: 11, design: .monospaced))
                    Button {
                        preferences.explicitRepositories.removeAll { $0 == repository }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }

            HStack(spacing: 6) {
                TextField("owner/repo", text: $newRepository)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addRepository() }
                Button("Add") { addRepository() }
                    .disabled(!newRepository.contains("/"))
            }
            .controlSize(.small)
        }
    }

    private func addRepository() {
        let trimmed = newRepository.trimmingCharacters(in: .whitespacesAndNewlines)
        // Case-insensitively, the way `Preferences.watchActor` already checks
        // the actor list beside it. GitHub does not distinguish `acme/api` from
        // `acme/API`, so an exact match let the same repository into the list
        // twice — and two entries mean two polls a cycle and the same run drawn
        // twice, under two identities. `RunMonitor` folds the case on its way
        // in as well; this is what stops the list looking wrong in Settings.
        guard trimmed.contains("/"),
              !preferences.explicitRepositories.contains(where: {
                  $0.caseInsensitiveCompare(trimmed) == .orderedSame
              })
        else { return }
        preferences.explicitRepositories.append(trimmed)
        newRepository = ""
    }

    // MARK: - Display

    private var display: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where to show the island")
                .font(.headline)

            ForEach(displayOptions) { displayRow($0) }

            // Only worth offering when there is more than one screen to choose
            // between: on a single display every one of these is the same row
            // as "Main display", said twice.
            if pinnedDisplayOptions.count > 1 {
                Text("Or pin it to one display")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)

                ForEach(pinnedDisplayOptions) { displayRow($0) }
            }

            Divider().padding(.vertical, 4)

            Toggle(isOn: $preferences.idleMark) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keep the mark in the notch when nothing is running")
                        .font(.system(size: 12, weight: .medium))
                    Text("The island stays as a band under the cutout, blended into it, "
                         + "with the Runway mark in it — blinking and looking around every "
                         + "so often. Notched Macs only: off a notch the resting island is "
                         + "a floating pill, and a pill that never leaves is furniture.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            // Indented under the toggle it belongs to, and dimmed with it: a
            // live-looking control for a mark that is switched off is a control
            // that does nothing.
            HStack(spacing: 8) {
                Text("Where in the notch")
                    .font(.system(size: 12))
                    .foregroundStyle(preferences.idleMark ? .primary : .tertiary)
                    .frame(width: markSettingLabelWidth, alignment: .leading)
                Picker("", selection: $preferences.idleMarkPosition) {
                    ForEach(IdleMarkPosition.allCases, id: \.self) { position in
                        Text(position.title).tag(position)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 210)
                Spacer()
            }
            .padding(.leading, 38)
            .disabled(!preferences.idleMark)

            // Swatches rather than a picker of colour names, and a short list
            // rather than a colour well: see `IdleMarkTint` for why a free
            // choice here is a choice you can make invisible.
            HStack(spacing: 8) {
                Text("Colour")
                    .font(.system(size: 12))
                    .foregroundStyle(preferences.idleMark ? .primary : .tertiary)
                    .frame(width: markSettingLabelWidth, alignment: .leading)
                HStack(spacing: 6) {
                    ForEach(IdleMarkTint.allCases, id: \.self) { tint in
                        tintSwatch(tint)
                    }
                }
                // `.disabled` dims a Picker for you and a plain Button not at
                // all, so the swatches say it themselves.
                .opacity(preferences.idleMark ? 1 : 0.4)
                Spacer()
            }
            .padding(.leading, 38)
            .disabled(!preferences.idleMark)
            .help("The light in the resting mark. The menu bar icon is a "
                  + "template image, so macOS keeps tinting that one.")

            Divider().padding(.vertical, 4)

            Toggle(isOn: Binding(
                get: { launchAtLogin },
                set: { wanted in
                    switch LaunchAtLogin.set(wanted) {
                    case .success(let actual):
                        launchAtLogin = actual
                        launchError = nil
                    case .failure(let error):
                        launchAtLogin = LaunchAtLogin.isEnabled
                        launchError = error.localizedDescription
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Launch at login")
                        .font(.system(size: 12, weight: .medium))
                    Text(launchError ?? LaunchAtLogin.statusDescription)
                        .font(.caption)
                        .foregroundStyle(launchError == nil ? Color.secondary.opacity(0.7) : Color.red)
                }
            }
            .toggleStyle(.switch)

            if LaunchAtLogin.wasDeniedBySystem {
                Button("Open Login Items…") { LaunchAtLogin.openSystemSettings() }
                    .controlSize(.small)
                    .padding(.leading, 2)
            }

            // Only when there is something to say. A permanent row reading
            // "0 runs hidden" is a setting that describes the absence of a
            // thing, and the island's × is discoverable enough that most
            // people will never see this at all.
            if dismissedCount > 0 {
                Divider().padding(.vertical, 4)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(dismissedCount == 1
                             ? "1 run hidden from the island"
                             : "\(dismissedCount) runs hidden from the island")
                            .font(.system(size: 12, weight: .medium))
                        Text("Hiding is local and temporary: the runs are untouched on "
                             + "GitHub, and each one is forgotten by itself after a "
                             + "fortnight. A re-run always comes back.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Show them again") {
                        onRestoreDismissed()
                        DismissedRuns.restore()
                        dismissedCount = 0
                    }
                    .controlSize(.small)
                }
            }
        }
        .onAppear { dismissedCount = DismissedRuns.count() }
    }

    // MARK: - Alerts

    /// Everything that reaches out rather than waiting to be looked at.
    ///
    /// One section because they answer the same question — *when should Runway
    /// interrupt you* — and because the two settings pull in opposite
    /// directions: a haptic is for the run you are already watching, a banner
    /// is for the one you are not.
    private var alerts: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Alerts")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Toggle(isOn: $preferences.approvalNotifications) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Tell me when a deployment needs my approval")
                                .font(.system(size: 12, weight: .medium))
                            markdown("A Notification Centre banner, only when GitHub says "
                                     + "**you** can approve it. A colleague's deploy reaching "
                                     + "production shows on the island in amber and is never "
                                     + "sent here.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    Spacer(minLength: 6)
                    overrideBadge(EnvironmentDefault.notifyApprovals)
                }

                if preferences.approvalNotifications {
                    notificationPermission
                }

                Text("Runway never approves anything for you: its token is read-only by "
                     + "design, so the banner and the menu both just open the run on GitHub. "
                     + "Granting a deployment is a write GitHub puts behind a separate "
                     + "permission, and asking for it would mean asking for a token that "
                     + "can deploy.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().padding(.vertical, 2)

            Toggle(isOn: $preferences.haptics) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Haptic feedback")
                        .font(.system(size: 12, weight: .medium))
                    Text(hapticsDetail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.switch)

            if preferences.haptics {
                HStack(spacing: 8) {
                    Text("Try:")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Button("Start") { Haptics.demoStart() }
                    Button("Success") { Haptics.demoSuccess() }
                    Button("Failure") { Haptics.demoFailure() }
                }
                .controlSize(.small)
                .padding(.leading, 2)
            }
        }
    }

    /// What macOS currently says, and the one button that can change it.
    @ViewBuilder
    private var notificationPermission: some View {
        let authorization = ApprovalNotifier.authorization
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(permissionColour(authorization))
                .frame(width: 7, height: 7)
            Text(authorization.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
        }
        .padding(.leading, 2)

        HStack(spacing: 8) {
            switch authorization {
            case .notDetermined:
                Button("Allow Notifications…") {
                    ApprovalNotifier.requestAuthorization { _ in }
                }
            case .denied:
                Button("Open Notification Settings") { ApprovalNotifier.openSystemSettings() }
                Button("Recheck") { ApprovalNotifier.refreshAuthorization() }
            case .authorized:
                Button("Send a test banner") { ApprovalNotifier.demo() }
            case .unavailable:
                Button("Recheck") { ApprovalNotifier.refreshAuthorization() }
            }
        }
        .controlSize(.small)
        .padding(.leading, 2)
    }

    private func permissionColour(_ authorization: ApprovalNotifier.Authorization) -> Color {
        switch authorization {
        case .authorized: return .green
        case .denied: return .orange
        case .notDetermined: return .secondary
        case .unavailable: return .orange
        }
    }

    /// Say plainly whether haptics can actually be felt on this hardware.
    private var hapticsDetail: String {
        Haptics.isSupported
            ? "A tap when a run starts, finishes, or fails. Requires a Force Touch trackpad."
            : "No Force Touch trackpad detected — haptics will not be felt on a mouse."
    }

    /// Keeps the two indented mark controls on one column. "Where in the
    /// notch" is the long label; the swatches line up under its picker.
    private var markSettingLabelWidth: CGFloat { 124 }

    /// One tint, drawn the way macOS draws an accent choice: the colour itself,
    /// a hairline so the white one still has an edge on a light window, and a
    /// ring around the one that is on. A button and not a tap gesture, so it is
    /// reachable from the keyboard and announced as selected.
    private func tintSwatch(_ tint: IdleMarkTint) -> some View {
        let isSelected = preferences.idleMarkTint == tint
        return Button {
            preferences.idleMarkTint = tint
        } label: {
            Circle()
                .fill(tint.swatch)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
                .frame(width: 16, height: 16)
                .padding(2)
                .overlay(
                    Circle().strokeBorder(
                        isSelected ? Color.accentColor : .clear, lineWidth: 2
                    )
                )
        }
        .buttonStyle(.plain)
        .help(tint.title)
        .accessibilityLabel(Text(tint.title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }

    private struct DisplayOption: Identifiable {
        let id: String
        let preference: NotchGeometry.ScreenPreference
        /// Set only on the per-display rows, which all share `.pinned` and so
        /// cannot be told apart by their preference alone.
        var pinnedID: CGDirectDisplayID? = nil
        let title: String
        let detail: String
    }

    @ViewBuilder
    private func displayRow(_ option: DisplayOption) -> some View {
        let selected = isChosen(option)
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(option.title)
                    .font(.system(size: 12, weight: .medium))
                Text(option.detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { choose(option) }
    }

    private func isChosen(_ option: DisplayOption) -> Bool {
        guard preferences.screenPreference == option.preference else { return false }
        guard let pinnedID = option.pinnedID else { return true }
        return preferences.pinnedDisplay == Int(pinnedID)
    }

    private func choose(_ option: DisplayOption) {
        // The display before the preference: writing them the other way round
        // sends the island to whichever display was pinned last time, for as
        // long as it takes the next line to run.
        if let pinnedID = option.pinnedID {
            preferences.pinnedDisplay = Int(pinnedID)
        }
        preferences.screenPreference = option.preference
    }

    /// Display choices, labelled with the actual attached screens.
    private var displayOptions: [DisplayOption] {
        let screens = NSScreen.screens
        func describe(_ screen: NSScreen?) -> String {
            guard let screen else { return "not attached" }
            return "\(screen.localizedName) — \(geometry(screen))"
        }

        let notched = screens.first(where: NotchGeometry.hasCutout)
        let builtIn = screens.first {
            NotchGeometry.hasCutout($0)
                || $0.localizedName.lowercased().contains("built-in")
                || $0.localizedName.lowercased().contains("liquid retina")
        }

        return [
            DisplayOption(
                id: "notched",
                preference: .notched,
                title: "Notch display",
                detail: notched.map(describe) ?? "No notched display attached — falls back to the menu bar display."
            ),
            DisplayOption(
                id: "primary",
                preference: .primary,
                title: "Main display",
                detail: describe(screens.first { $0.frame.origin == .zero } ?? screens.first)
            ),
            DisplayOption(
                id: "active",
                preference: .main,
                title: "Active display",
                detail: "Whichever screen the pointer is on — the island follows you between them."
            ),
            DisplayOption(
                id: "builtIn",
                preference: .builtIn,
                title: "Built-in display",
                detail: builtIn.map(describe) ?? "Lid closed or no built-in display detected."
            ),
        ]
    }

    /// One row per attached screen, for naming a display outright.
    ///
    /// The four choices above are all *roles*, and on a MacBook driving an
    /// external monitor every one of them resolves back to the MacBook — there
    /// was no way to say "put it on the monitor" at all.
    private var pinnedDisplayOptions: [DisplayOption] {
        NSScreen.screens.compactMap { screen in
            guard let id = NotchGeometry.displayID(of: screen) else { return nil }
            return DisplayOption(
                id: "display-\(id)",
                preference: .pinned,
                pinnedID: id,
                title: screen.localizedName,
                detail: geometry(screen)
            )
        }
    }

    /// The part of a screen's label that is not its name.
    private func geometry(_ screen: NSScreen) -> String {
        let size = "\(Int(screen.frame.width))×\(Int(screen.frame.height))"
        let notch = NotchGeometry.hasCutout(screen) ? ", has a notch" : ""
        let menuBar = screen.frame.origin == .zero ? ", menu bar" : ""
        return "\(size)\(notch)\(menuBar)"
    }

    // MARK: - Account

    private var account: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("GitHub Account")
                .font(.headline)

            HStack(spacing: 8) {
                Circle()
                    .fill(tokenStatus.colour)
                    .frame(width: 8, height: 8)
                Text(tokenStatus.label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                if isVerifying {
                    ProgressView().controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                Text("Host")
                    .frame(width: 46, alignment: .leading)
                TextField("https://github.com", text: $preferences.host)
                    .textFieldStyle(.roundedBorder)
                overrideBadge(EnvironmentDefault.host)
            }

            HStack(spacing: 8) {
                Text("Token")
                    .frame(width: 46, alignment: .leading)
                SecureField("github_pat_… or ghp_…", text: $tokenField)
                    .textFieldStyle(.roundedBorder)
                Button("Save") { saveToken() }
                    .disabled(tokenField.isEmpty)
            }

            markdown("Create a **fine-grained** token with **Actions: Read** — that one box "
                     + "— and select the repositories you want to watch. That single permission "
                     + "also covers the approval check, so nothing here asks for more than it "
                     + "did. It is stored in your macOS Keychain, never on disk. A classic "
                     + "token with the `repo` scope also works, but grants far more.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("Open GitHub Token Settings") {
                    let origin = GitHubClient.webOrigin(for: preferences.host)
                    if let url = URL(string: origin + "/settings/personal-access-tokens/new") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Verify") { checkToken(force: true) }
                Button("Remove Token", role: .destructive) { removeToken() }
            }
            .controlSize(.small)
        }
    }

    // MARK: - Token actions

    private func saveToken() {
        let trimmed = tokenField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try Keychain.store(trimmed)
            tokenField = ""
            onTokenChanged()
            checkToken(force: true)
        } catch {
            tokenStatus = .invalid(error.localizedDescription)
        }
    }

    private func removeToken() {
        try? Keychain.delete()
        tokenStatus = .missing
        preferences.currentUser = nil
        organizations = []
        onTokenChanged()
    }

    /// Fetch the organizations this token can see — and, when it can't see
    /// them, why.
    ///
    /// This was a `try?` that dropped the error on the floor, which produced
    /// the single most confusing state the app had: a token that verifies
    /// green, an empty organization list, and nothing to explain the gap. It
    /// is worth being precise about why that happens, because GitHub gives no
    /// error for the common case:
    ///
    ///  * A **classic** token in a SAML org must be authorized for that org
    ///    after it is created. Until it is, `/user/orgs` still returns `200`
    ///    — just without that org — and says so only in `X-GitHub-SSO:
    ///    partial-results`.
    ///  * A **fine-grained** token is bound to one resource owner. Pointed at
    ///    a personal account it can never see an org, and pointed at the org
    ///    it stays inert until an admin approves it. Neither is an error
    ///    either: the list is simply empty.
    ///
    /// So an empty list is never self-explanatory, and it now explains itself.
    private func loadOrganizations(force: Bool = false) {
        guard TokenCache.shared.token() != nil else { return }
        guard force || organizations.isEmpty else { return }
        // Two call sites can fire in the same frame — the picker's `onAppear`
        // and the tap that selected the scope it appeared under — and neither
        // `force` nor the empty check separates them, since the first request
        // has not come back yet when the second is made. One `Reload` click
        // while the first is still in flight does the same. Whichever landed
        // last won, so a stale response could overwrite a newer one.
        guard !isLoadingOrganizations else { return }
        isLoadingOrganizations = true
        Task {
            let client = GitHubClient(baseURL: GitHubClient.baseURL(for: Preferences.shared.host))
            // Immutable, and assigned exactly once on each path: `MainActor.run`
            // takes a `@Sendable` closure, and Swift 6 refuses to let one
            // capture a mutable local.
            let outcome: (organizations: [Organization], failure: String?)
            do {
                outcome = (try await client.fetchOrganizations(), nil)
            } catch {
                let message = (error as? GitHubError)?.errorDescription
                    ?? error.localizedDescription
                outcome = ([], message)
            }
            // Read after the call: the header rides on the response that
            // dropped the rows.
            let notice = await client.currentSSONotice()
            await MainActor.run {
                organizations = outcome.organizations.sorted { $0.login < $1.login }
                organizationError = outcome.failure
                organizationSSO = notice
                isLoadingOrganizations = false
            }
        }
    }

    private func checkToken(force: Bool = false) {
        guard TokenCache.shared.token() != nil else {
            tokenStatus = .missing
            return
        }
        guard force || tokenStatus == .unknown else { return }
        // The same guard `loadOrganizations` carries, and missing here for the
        // same reason it was missing there: neither `force` nor the status
        // check separates two calls made before the first has come back.
        // Nothing disables the Verify button while the spinner is up, so a
        // second click is one more round trip and a second writer of
        // `tokenStatus` — and `saveToken()` calls this with `force` while the
        // picker's `onAppear` may have one in flight already. Whichever landed
        // last won, so a stale answer could overwrite a newer one.
        guard !isVerifying else { return }
        isVerifying = true
        Task {
            let client = GitHubClient(baseURL: GitHubClient.baseURL(for: Preferences.shared.host))
            do {
                let user = try await client.fetchAuthenticatedUser()
                await MainActor.run {
                    tokenStatus = .stored(login: user.login)
                    Preferences.shared.currentUser = user.login
                    isVerifying = false
                }
            } catch {
                await MainActor.run {
                    let message = (error as? GitHubError)?.errorDescription
                        ?? error.localizedDescription
                    tokenStatus = .invalid(message)
                    isVerifying = false
                }
            }
        }
    }

    /// `Text` over a string built at runtime, with markdown still parsed.
    ///
    /// `Text("a" + "b")` picks the `StringProtocol` overload, and that one does
    /// not read markdown — which is why the token advice below used to render
    /// its own asterisks on screen. Naming the key type puts it back on the
    /// overload that does.
    private func markdown(_ string: String) -> Text {
        Text(LocalizedStringKey(string))
    }

    /// A "$RUNWAY_X is set" hint with a one-click reset back to its value.
    ///
    /// Deliberately not a lock. The variable seeded this setting's default;
    /// changing it here is allowed and wins from then on. Greying the control
    /// out would mean a stray variable in a shell profile leaves you unable to
    /// fix your own settings from inside the app.
    @ViewBuilder
    private func overrideBadge(_ name: String) -> some View {
        if EnvironmentDefault.isSet(name) {
            Button {
                preferences.resetToEnvironment(name)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 8))
                    Text(name)
                        .font(.system(size: 9, design: .monospaced))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .help("\(name)=\(EnvironmentDefault.string(name) ?? "") is set in your environment "
                  + "and seeded this setting. Click to go back to it.")
        }
    }
}

extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
