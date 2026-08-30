import AppKit
import SwiftUI

/// Settings window.
@MainActor
public final class SettingsWindowController {
    private var window: NSWindow?
    private let model: IslandModel
    private let onTokenChanged: () -> Void

    public init(model: IslandModel, onTokenChanged: @escaping () -> Void) {
        self.model = model
        self.onTokenChanged = onTokenChanged
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
    let onClose: () -> Void

    @State private var preferences = Preferences.shared
    @State private var tokenField = ""
    @State private var tokenStatus: TokenStatus = .unknown
    @State private var isVerifying = false
    @State private var organizations: [Organization] = []
    @State private var isLoadingOrganizations = false
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    @State private var newActor = ""
    @State private var actorError: String?
    @State private var newRepository = ""

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
        return "Watching \(names). Runway reads the 30 most recent runs per repository and "
            + "keeps the ones these people pushed or re-ran. GitHub's own ?actor= filter is not "
            + "used: it matches the push author, so it cannot see a run you re-ran for someone else."
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
    private func runCount(for option: ActorScope) -> Int? {
        let runs = model.state.runs
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
            } else if organizations.isEmpty {
                HStack(spacing: 8) {
                    Text("No organizations found for this account.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Reload") { loadOrganizations(force: true) }
                        .controlSize(.small)
                }
            } else {
                ForEach(organizations) { organization in
                    Toggle(isOn: Binding(
                        get: { preferences.organizations.contains(organization.login) },
                        set: { on in
                            if on { preferences.organizations.insert(organization.login) }
                            else { preferences.organizations.remove(organization.login) }
                        }
                    )) {
                        Text(organization.login)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
        .onAppear { loadOrganizations() }
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
        guard trimmed.contains("/"), !preferences.explicitRepositories.contains(trimmed) else { return }
        preferences.explicitRepositories.append(trimmed)
        newRepository = ""
    }

    // MARK: - Display

    private var display: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where to show the island")
                .font(.headline)

            ForEach(displayOptions, id: \.preference) { option in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: preferences.screenPreference == option.preference
                          ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(preferences.screenPreference == option.preference
                                         ? Color.accentColor : .secondary)
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
                .onTapGesture { preferences.screenPreference = option.preference }
            }

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

    /// Say plainly whether haptics can actually be felt on this hardware.
    private var hapticsDetail: String {
        Haptics.isSupported
            ? "A tap when a run starts, finishes, or fails. Requires a Force Touch trackpad."
            : "No Force Touch trackpad detected — haptics will not be felt on a mouse."
    }

    private struct DisplayOption {
        let preference: NotchGeometry.ScreenPreference
        let title: String
        let detail: String
    }

    /// Display choices, labelled with the actual attached screens.
    private var displayOptions: [DisplayOption] {
        let screens = NSScreen.screens
        func describe(_ screen: NSScreen?) -> String {
            guard let screen else { return "not attached" }
            let size = "\(Int(screen.frame.width))×\(Int(screen.frame.height))"
            let notch = screen.safeAreaInsets.top > 0 ? ", has a notch" : ""
            return "\(screen.localizedName) — \(size)\(notch)"
        }

        let notched = screens.first { $0.safeAreaInsets.top > 0 }
        let builtIn = screens.first {
            $0.safeAreaInsets.top > 0
                || $0.localizedName.lowercased().contains("built-in")
                || $0.localizedName.lowercased().contains("liquid retina")
        }

        return [
            DisplayOption(
                preference: .notched,
                title: "Notch display",
                detail: notched.map(describe) ?? "No notched display attached — falls back to the menu bar display."
            ),
            DisplayOption(
                preference: .primary,
                title: "Main display",
                detail: describe(screens.first { $0.frame.origin == .zero } ?? screens.first)
            ),
            DisplayOption(
                preference: .main,
                title: "Active display",
                detail: "Wherever the keyboard focus is — the island follows you between screens."
            ),
            DisplayOption(
                preference: .builtIn,
                title: "Built-in display",
                detail: builtIn.map(describe) ?? "Lid closed or no built-in display detected."
            ),
        ]
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

            Text("Create a **fine-grained** token with **Actions: Read** and **Contents: Read** "
                 + "on the repositories you want to watch. It is stored in your macOS Keychain, "
                 + "never on disk. A classic token with the `repo` scope also works.")
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

    private func loadOrganizations(force: Bool = false) {
        guard TokenCache.shared.token() != nil else { return }
        guard force || organizations.isEmpty else { return }
        isLoadingOrganizations = true
        Task {
            let client = GitHubClient(baseURL: GitHubClient.baseURL(for: Preferences.shared.host))
            let result = try? await client.fetchOrganizations()
            await MainActor.run {
                if let result {
                    organizations = result.sorted { $0.login < $1.login }
                }
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
