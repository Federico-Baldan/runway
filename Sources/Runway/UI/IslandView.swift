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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .overlay(alignment: .bottom) { RunwayStripe(mood: model.mood, isBusy: model.mood == .running) }
        .overlay(
            shape.strokeBorder(edgeHighlight, lineWidth: 1)
        )
        .clipShape(shape)
        .shadow(color: .black.opacity(model.isExpanded ? 0.42 : 0.24),
                radius: model.isExpanded ? 22 : 10, y: 5)
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

                if model.relevantRuns.count > 1 {
                    Text("\(model.relevantRuns.count)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .padding(.horizontal, 4)
                        .padding(.vertical, 0.5)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                }
            } else if model.state.error != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(StatusPalette.fault)
                    .shadow(color: StatusPalette.fault.opacity(0.5), radius: 3)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .frame(height: 14)
        .padding(.bottom, 4)
        .transition(.opacity)
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

    /// The island's ground.
    ///
    /// Under a cutout it has to be *actually* black — the display's own pixels
    /// continue the hardware — so the depth has to come from something other
    /// than transparency: a barely-there vertical lift, and a wash of the
    /// current mood's colour pooling at the bottom edge. Off a notch there is a
    /// real window behind it, so the material does that work instead.
    private var background: some View {
        ZStack {
            Color.black.opacity(hasNotch ? 1.0 : 0.90)

            if !hasNotch {
                VisualEffectBackground().opacity(0.38)
            }

            LinearGradient(
                colors: [Color.white.opacity(0.055), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )

            LinearGradient(
                colors: [Color.clear, StatusStyle.color(for: model.mood).opacity(moodWash)],
                startPoint: .top,
                endPoint: .bottom
            )
            .animation(Motion.content, value: model.mood)
        }
    }

    /// How strongly the mood tints the island's lower edge.
    private var moodWash: Double {
        switch model.mood {
        case .idle: return 0.04
        case .approval, .error: return 0.16
        default: return 0.10
        }
    }

    /// A hairline that is brighter at the top than the sides, the way a real
    /// bevel catches light.
    private var edgeHighlight: LinearGradient {
        LinearGradient(
            colors: hasNotch
                ? [Color.white.opacity(0.10), Color.white.opacity(0.02)]
                : [Color.white.opacity(0.16), Color.white.opacity(0.04)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// The divider between the pill and its expansion. A `Divider()` draws a
    /// full-bleed system line that reaches the rounded corners and cuts them.
    private var hairline: some View {
        LinearGradient(
            colors: [Color.white.opacity(0), Color.white.opacity(0.16), Color.white.opacity(0)],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 1)
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
                noticeRow(
                    symbol: "circle.dashed",
                    tint: Color.white.opacity(0.26),
                    text: "nothing running"
                )

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
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 1)
            .padding(.horizontal, 12)
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
        HStack(spacing: 7) {
            Image(systemName: model.state.isPolling ? "antenna.radiowaves.left.and.right" : "pause.circle")
                .font(.system(size: 8))
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
            Button(action: onQuit) {
                Text("Quit")
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.55))
        }
        .font(.system(size: 9))
        .foregroundStyle(.white.opacity(0.42))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

/// The light strip along the island's bottom edge.
///
/// The one piece of chrome that is purely for the feel of the thing, and the
/// app's own name is the argument for it: a runway is a dark strip with lights
/// down it. It carries the mood colour, and while something is building a
/// brighter segment travels along it — so the island reads as *live* from the
/// corner of your eye, at a glance too short to focus on a glyph.
struct RunwayStripe: View {
    let mood: IslandMood
    var isBusy: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    private var tint: Color { StatusStyle.color(for: mood) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                LinearGradient(
                    colors: [tint.opacity(0), tint.opacity(0.55), tint.opacity(0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                if isBusy && !reduceMotion {
                    LinearGradient(
                        colors: [tint.opacity(0), tint, tint.opacity(0)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: proxy.size.width * 0.32)
                    .offset(x: sweep ? proxy.size.width * 0.84 : -proxy.size.width * 0.16)
                    .animation(
                        .easeInOut(duration: 2.1).repeatForever(autoreverses: false),
                        value: sweep
                    )
                }
            }
        }
        .frame(height: 1.5)
        .opacity(mood == .idle ? 0.35 : 1)
        .animation(Motion.content, value: mood)
        .onAppear { sweep = isBusy && !reduceMotion }
        .onChange(of: isBusy) { _, busy in sweep = busy && !reduceMotion }
        .allowsHitTesting(false)
    }
}

/// Per-run job detail, shown only when the island is expanded.
struct JobDetail: View {
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

            ForEach(run.jobList) { job in
                HStack(alignment: .center, spacing: 7) {
                    StatusGlyph(status: job.status, size: 8, blocked: job.isBlockedOnApproval)
                    Text(job.name)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(StatusStyle.color(for: job.status).opacity(0.95))
                        .frame(width: 74, alignment: .leading)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(job.name)

                    FlowLayout(spacing: 10, lineSpacing: 3) {
                        ForEach(job.steps) { step in
                            HStack(spacing: 4) {
                                StepDot(status: step.status, name: step.name, job: job.name)
                                Text(step.name)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(step.status == .inProgress
                                                     ? Color.white.opacity(0.92)
                                                     : Color.white.opacity(0.55))
                                    .lineLimit(1)
                            }
                        }
                        if job.steps.isEmpty {
                            Text("—")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    }
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var accent: Color { StatusStyle.color(for: IslandModel.mood(for: run)) }

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

            if let symbol = StatusStyle.eventSymbol(for: run.event) {
                Image(systemName: symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.32))
                    .help(run.event ?? "")
            }

            if let branch = run.headBranch {
                Text(branch)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
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
        .background(alignment: .leading) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.075 : 0))
                    .padding(.horizontal, 5)
                // A 2pt rail in the run's own colour, revealed on hover: the
                // row you are pointing at says what it is without a tooltip.
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(accent)
                    .frame(width: 2.5, height: isHovering ? 18 : 0)
                    .padding(.leading, 5)
                    .opacity(isHovering ? 1 : 0)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.spring(duration: 0.26, bounce: 0.2)) { isHovering = hovering }
        }
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
