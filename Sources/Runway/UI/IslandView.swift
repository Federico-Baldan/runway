import AppKit
import SwiftUI

/// The island itself: a collapsed pill that expands on hover.
struct IslandView: View {
    @Bindable var model: IslandModel
    /// True when the panel is tucked under a physical notch cutout.
    let hasNotch: Bool
    /// Height of the notch cutout in points, 0 on a notchless display.
    var notchHeight: CGFloat = 0
    /// Notch width, so the resting island is never narrower than the cutout.
    var notchWidth: CGFloat = 0
    let onOpen: (WorkflowRun) -> Void
    let onQuit: () -> Void
    /// Routed through the controller so the resize is sequenced around the animation.
    var onHoverChange: (Bool) -> Void = { _ in }

    /// True while animating out; selects the gentler exit geometry.
    private var isLeaving: Bool { model.isLeaving }

    var body: some View {
        VStack(spacing: 0) {
            // On a notched Mac the top band of the island sits behind the
            // physical cutout. The band is reserved in FULL in every state:
            // the cutout is opaque hardware, so nothing may be drawn under it,
            // ever — shrinking it when expanded puts the first row of text
            // physically behind the camera housing.
            if hasNotch {
                Color.clear.frame(height: notchHeight)
            }

            if isCompactRest {
                restBadge
            } else {
                collapsed
                if model.isExpanded {
                    hairline
                    expanded
                }
            }
        }
        .frame(width: currentWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(background)
        .clipShape(shape)
        // No border under a cutout, at any opacity.
        //
        // The island's whole trick is that its black is the *same* black as the
        // camera housing, so the two read as one object. A hairline around it —
        // even the barely-there gradient this used to draw — is a seam right
        // where the hardware ends, and once you see it you cannot unsee it.
        // Off a notch there is a real window edge to describe, so the border
        // comes back.
        .overlay(
            shape.strokeBorder(Color.white.opacity(hasNotch ? 0 : 0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(model.isExpanded ? 0.35 : 0.2),
                radius: model.isExpanded ? 18 : 8, y: 4)
        .scaleEffect(
            x: model.isOnScreen ? 1 : (isLeaving ? 0.97 : 0.86),
            y: model.isOnScreen ? 1 : (isLeaving ? 0.80 : 0.55),
            anchor: .top
        )
        .opacity(model.isOnScreen
                 ? (model.isExpanded ? 1 : 1 - model.settleProgress * 0.55)
                 : 0)
        .blur(radius: model.isOnScreen ? 0 : (isLeaving ? 1.5 : 3))
        // Hover and hit-testing belong to the DRAWN pill, not the canvas.
        //
        // The window is a fixed 620pt-wide canvas so expansion never resizes it,
        // but the collapsed pill is only ~52pt tall. Attaching `.onHover` to the
        // outer frame would make the whole invisible area a hover target, so the
        // island would expand from anywhere below it and swallow the mouse on
        // its way to a window underneath. `contentShape` scopes both hover and
        // clicks to the pill's actual silhouette.
        .contentShape(shape)
        .onHover { hovering in
            onHoverChange(hovering)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(true)
        .animation(Motion.content, value: model.stateSignature)
        .animation(Motion.expand, value: model.isExpanded)
    }

    /// True when the island should sit at exactly notch width.
    private var isCompactRest: Bool {
        hasNotch && !model.isExpanded
    }

    /// Width of the drawn island for the current state.
    private var currentWidth: CGFloat {
        model.isExpanded
            ? NotchGeometry.Width.expanded
            : NotchGeometry.Width.resting(hasNotch: hasNotch, notchWidth: notchWidth)
    }

    /// Resting badge for a notched Mac.
    ///
    /// Everything the island knows, in about eleven points of height: the worst
    /// run's state as a mark, how far through it is as the ring around that
    /// mark, and how many others there are. It is the only thing most people
    /// will ever see, so it is the piece that has to survive being glanced at.
    private var restBadge: some View {
        HStack(spacing: 5) {
            Spacer(minLength: 0)
            if let run = model.headline {
                StatusGlyph(
                    status: run.status,
                    size: 11,
                    progress: run.isActive ? run.progress : nil,
                    blocked: run.isBlockedOnApproval
                )
                .transition(.scale(scale: 0.4).combined(with: .opacity))
                .id(run.identity)

                // The one thing worth two more points of width up here. A
                // glyph says how the run is doing; on a deploy, *where* it is
                // going is the half of the sentence you cannot afford to have
                // to hover for.
                if let target = run.deployTarget {
                    EnvironmentChip(target: target, size: .micro)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }

                if model.relevantRuns.count > 1 {
                    Text("\(model.relevantRuns.count)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            } else if model.state.error != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(StatusPalette.fault)
                    .shadow(color: StatusPalette.fault.opacity(0.5), radius: 3)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            } else if model.showsIdleMark {
                // Nothing running, nothing wrong: the mark sits in the notch
                // and blinks. See `IdleMark` for why the island is on screen
                // at all in this state, and what it costs.
                IdleMark(height: 9, isSuspended: model.isSuspended)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .frame(height: isIdle ? 11 : 14)
        .padding(.bottom, isIdle ? 3 : 4)
        .transition(.opacity)
    }

    /// Nothing to report: no runs on screen and nothing broken.
    private var isIdle: Bool {
        model.headline == nil && model.state.error == nil
    }

    // MARK: - Chrome

    /// Square top edge under a cutout, fully rounded otherwise.
    private var shape: some InsettableShape {
        UnevenRoundedRectangle(
            topLeadingRadius: hasNotch ? 0 : 14,
            bottomLeadingRadius: hasNotch ? 18 : 14,
            bottomTrailingRadius: hasNotch ? 18 : 14,
            topTrailingRadius: hasNotch ? 0 : 14,
            style: .continuous
        )
    }

    /// The island's ground: black, and nothing else.
    ///
    /// Under a cutout it has to be *actually* black — the display's own pixels
    /// continue the hardware. There used to be a vertical lift gradient and a
    /// wash of the current mood's colour pooling at the bottom edge on top of
    /// that, which is two more layers than a status pill has any business
    /// carrying: the mood is already said by every glyph on it. Off a notch the
    /// material does the depth, the way it did before.
    private var background: some View {
        ZStack {
            Color.black.opacity(hasNotch ? 1.0 : 0.92)

            if !hasNotch {
                VisualEffectBackground().opacity(0.35)
            }
        }
    }

    /// The divider between the pill and its expansion. Inset, because a bare
    /// `Divider()` is full-bleed and cuts across the rounded corners.
    private var hairline: some View {
        Divider()
            .opacity(0.35)
            .padding(.horizontal, 10)
    }

    // MARK: - Collapsed pill

    /// The collapsed island: **one line per run**, stacked.
    private var collapsed: some View {
        VStack(spacing: 0) {
            if let error = model.state.error {
                noticeRow(
                    symbol: "exclamationmark.triangle.fill",
                    tint: StatusPalette.fault,
                    text: error
                )

            } else if model.collapsedRuns.isEmpty {
                // The expanded form of the resting mark. Hovering the island is
                // the one moment somebody is definitely looking at it, so the
                // eye looks back instead of wandering off.
                if model.showsIdleMark {
                    HStack(spacing: 8) {
                        IdleMark(height: 11, isSuspended: model.isSuspended, isAttentive: true)
                            .frame(width: 16)
                        Text("nothing running")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.34))
                            .lineLimit(1)
                        Spacer(minLength: 2)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .transition(.opacity)
                } else {
                    noticeRow(
                        symbol: "circle.dashed",
                        tint: Color.white.opacity(0.26),
                        text: "nothing running"
                    )
                }

            } else {
                ForEach(Array(model.collapsedRuns.enumerated()), id: \.element.id) { index, run in
                    if index > 0 { rowSeparator }
                    RunLine(
                        run: run,
                        now: model.now,
                        showActor: model.showsMultipleActors,
                        onOpen: onOpen
                    )
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top)
                                .combined(with: .opacity)
                                .combined(with: .scale(scale: 0.96, anchor: .top)),
                            removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
                        )
                    )
                }

                // Overflow, when more runs are live than the pill will show.
                if model.hiddenRunCount > 0 {
                    HStack(spacing: 4) {
                        Spacer()
                        Image(systemName: "ellipsis")
                            .font(.system(size: 8, weight: .bold))
                        Text("\(model.hiddenRunCount) more — hover to see all")
                            .font(.system(size: 9))
                        Spacer()
                    }
                    .foregroundStyle(.white.opacity(0.42))
                    .frame(height: 18)
                    .transition(.opacity)
                }
            }
        }
    }

    private func noticeRow(symbol: String, tint: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 13)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(tint.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 2)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .transition(.opacity)
    }

    private var rowSeparator: some View {
        Divider()
            .opacity(0.14)
            .padding(.horizontal, 10)
    }

    // MARK: - Expanded panel

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.expandedDetail) { run in
                JobDetail(run: run, showActor: model.showsMultipleActors, onOpen: onOpen)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
            }

            if model.expandedDetail.isEmpty {
                Text(model.state.error ?? "Nothing running right now.")
                    .font(.system(size: 11))
                    .foregroundStyle(StatusPalette.quiet)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .transition(.opacity)
            }

            hairline.padding(.vertical, 3)

            footer
        }
        .padding(.top, 5)
        .clipped()
        .transition(
            .asymmetric(
                insertion: .opacity.animation(Motion.expand.delay(0.06)),
                removal: .opacity.animation(.easeOut(duration: 0.12))
            )
        )
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let lastUpdate = model.state.lastUpdate {
                Text("updated \(IslandFormat.duration(model.now.timeIntervalSince(lastUpdate))) ago")
                    .monospacedDigit()
                    .contentTransition(.numericText())
            } else {
                Text("connecting…")
            }
            if model.state.rateLimit.limit > 0 {
                Text("·")
                Text("\(model.state.rateLimit.remaining) API left")
                    .monospacedDigit()
                    .help("Requests remaining this hour. Resets in \(model.state.rateLimit.resetDescription).")
            }
            Spacer()
            Button("Quit", action: onQuit)
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.55))
        }
        .font(.system(size: 9))
        .foregroundStyle(.white.opacity(0.42))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}

/// Per-run job detail, shown only when the island is expanded.
struct JobDetail: View {
    /// How many step dots a job draws before it starts counting instead.
    ///
    /// Twenty-four at 7pt plus 3pt of air is 240pt, which fits inside the
    /// 620pt expanded island next to a 96pt job name with room left for the
    /// running step's label.
    static let stepDotLimit = 24

    let run: WorkflowRun
    var showActor: Bool = false
    var onOpen: (WorkflowRun) -> Void = { _ in }

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                StatusGlyph(
                    status: run.status,
                    size: 10,
                    progress: run.isActive ? run.progress : nil,
                    blocked: run.isBlockedOnApproval
                )
                Text(run.repositoryName)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                Text("#\(run.runNumber)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                if run.runAttempt > 1 {
                    Text("attempt \(run.runAttempt)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
                if let target = run.deployTarget, !run.isBlockedOnApproval {
                    EnvironmentChip(target: target, size: .compact)
                }
                if showActor { ActorChip(run: run, compact: true) }
                Spacer(minLength: 0)
                if run.isBlockedOnApproval {
                    ApprovalChip(run: run)
                }
            }

            if run.jobList.isEmpty {
                Text(run.isActive ? "waiting for a runner…" : "no job detail")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }

            // One line per job: the mark, the name, the steps as dots, and the
            // name of the step actually running.
            //
            // The dots used to carry a label each. On a real workflow that is
            // twenty of them — "Set up job", "Post Run actions/create-github-app-token@1b10c78…",
            // one line per action, SHA and all — and the expanded island became
            // a wall of text taller than the window it hangs from, which is
            // what a run's page on GitHub is already for. The dots keep every
            // step's *state*, which is the part you cannot get at a glance
            // anywhere else; the one name worth printing is the step that is
            // running right now, and it gets printed once.
            ForEach(run.jobList) { job in
                HStack(alignment: .center, spacing: 7) {
                    StatusGlyph(status: job.status, size: 8, blocked: job.isBlockedOnApproval)
                    Text(job.name)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(StatusStyle.color(for: job.status).opacity(0.95))
                        .frame(width: 96, alignment: .leading)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(job.name)

                    // A fixed strip, not a flow. `FlowLayout` reports whatever
                    // width it is offered, so in an `HStack` it takes the lot
                    // and leaves the step name beside it nothing to render in.
                    // Capped instead: a job with sixty steps is a job whose
                    // dots stopped being readable long before sixty.
                    HStack(spacing: 3) {
                        ForEach(Array(job.steps.prefix(Self.stepDotLimit))) { step in
                            StepDot(status: step.status, name: step.name, job: job.name)
                        }
                        if job.steps.count > Self.stepDotLimit {
                            Text("+\(job.steps.count - Self.stepDotLimit)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.38))
                        }
                        if job.steps.isEmpty {
                            Text("—")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    }
                    .fixedSize()

                    if let running = job.steps.first(where: { $0.status == .inProgress }) {
                        Text(running.name)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 0)
                }
            }

            // Who GitHub will accept a click from. Worth the line: "waiting for
            // approval" with no name attached is the difference between knowing
            // to go and ask somebody and staring at a stuck deploy.
            if let reviewers = reviewerLine {
                Text(reviewers)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(StatusPalette.approval.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(isHovering ? 0.06 : 0))
                .padding(.horizontal, 5)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) { isHovering = hovering }
        }
        .onTapGesture { onOpen(run) }
    }

    /// `reviewers: @alice, @acme/platform`, when GitHub told us who they are.
    private var reviewerLine: String? {
        let names = run.pendingDeployments
            .flatMap(\.reviewers)
            .map(\.handle)
        guard !names.isEmpty else { return nil }
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }
        return "can approve: " + unique.prefix(4).joined(separator: ", ")
            + (unique.count > 4 ? " +\(unique.count - 4)" : "")
    }
}

/// One run as a single compact line, for the collapsed island.
struct RunLine: View {
    let run: WorkflowRun
    let now: Date
    var showActor: Bool = false
    let onOpen: (WorkflowRun) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            StatusGlyph(
                status: run.status,
                size: 13,
                progress: run.isActive ? run.progress : nil,
                blocked: run.isBlockedOnApproval
            )
            .frame(width: 13)

            Text(run.repositoryName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .layoutPriority(3)

            if let branch = run.headBranch {
                Text(branch)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
            }

            // Not while the approval chip is up: that one already names the
            // environment, and the same word twice on a 32pt row is the kind
            // of duplication that makes a pill look automated rather than
            // written.
            if let target = run.deployTarget, !run.isBlockedOnApproval {
                EnvironmentChip(target: target, size: .compact)
                    .layoutPriority(2)
            }

            if showActor { ActorChip(run: run, compact: true) }

            JobTrack(run: run, compact: true)
                .layoutPriority(2)

            // An approval outranks the running-job label: they cannot both
            // be true, and only one of them is asking for something.
            if run.isBlockedOnApproval {
                ApprovalChip(run: run, compact: true)
                    .layoutPriority(2)
            } else if let job = run.runningJobs.first {
                Text(job.name)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.66))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            timing
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(isHovering ? 0.07 : 0))
                .padding(.horizontal, 5)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { onOpen(run) }
        .help(helpText)
    }

    @ViewBuilder
    private var timing: some View {
        if run.isBlockedOnApproval {
            // Elapsed time on a blocked run is the wrong number — it counts
            // how long a runner has been idle. How long it has been *waiting*
            // is the one people react to.
            Text(waitingLabel)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(StatusPalette.approval.opacity(0.9))
                .monospacedDigit()
                .contentTransition(.numericText())
                .help("Waiting for an approval for this long")
        } else if run.isActive {
            Text(IslandFormat.elapsed(run, now: now) ?? "—")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.88))
                .monospacedDigit()
                .contentTransition(.numericText())
                .help("Running for this long")
        } else if let seconds = run.duration {
            HStack(spacing: 3) {
                Image(systemName: "timer")
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.32))
                Text(IslandFormat.duration(seconds))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.58))
                    .monospacedDigit()
            }
            .help("Took \(IslandFormat.duration(seconds)) to run")
        }
    }

    private var waitingLabel: String {
        guard let since = run.updatedAt ?? run.startedAt else { return "—" }
        return IslandFormat.duration(now.timeIntervalSince(since))
    }

    private var helpText: String {
        if let summary = run.approvalSummary {
            return "\(run.repository) #\(run.runNumber) — \(summary). Click to open it on GitHub."
        }
        return "Open \(run.repository) run #\(run.runNumber) in the browser"
    }
}

/// A minimal flow layout: lay children out left to right, wrap when full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// `NSVisualEffectView` bridge: `.ultraThinMaterial` misreads inside a borderless panel.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
