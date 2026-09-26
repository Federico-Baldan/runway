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
    /// Take one run off the island. Local — see `DismissedRuns`.
    var onDismiss: (WorkflowRun) -> Void = { _ in }
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
        // Content lives inside the DRAWN island, not inside its frame.
        //
        // Under a cutout `IslandShape` insets its straight sides by a shoulder
        // each, so the frame is 12pt wider than the black either side of it —
        // dead width that belongs to the concave flare. Every row below pads
        // itself from the frame, which off a notch is the same thing and under
        // one is not: at rest the badge subtracted the shoulder by hand, but
        // the expanded panel never did, so its rows sat flush against the
        // island's edge and the footer — padded 10 where the shoulder is 12 —
        // was clipped by the very shape it was drawn in. Paying it once here
        // keeps the two states honest with one number.
        .padding(.horizontal, contentInset)
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

    /// How far in from the frame the content has to start.
    ///
    /// The shoulder under a cutout, nothing off one: `IslandShape` draws its
    /// body inset by that much on each side, and anything painted out there is
    /// painted on the flare — or, past it, clipped away entirely.
    private var contentInset: CGFloat {
        hasNotch ? NotchGeometry.Width.shoulder : 0
    }

    /// Resting badge for a notched Mac.
    ///
    /// Everything the island knows, in about eleven points of height: the worst
    /// run's state as a mark, how far through it is as the ring around that
    /// mark, and how many others there are. It is the only thing most people
    /// will ever see, so it is the piece that has to survive being glanced at.
    private var restBadge: some View {
        HStack(spacing: 5) {
            if let run = model.headline {
                // Indeterminate on purpose: under the cutout the ring is only
                // the sweep, never the blue arc of settled steps. At eleven
                // points a frozen arc beside a moving head read as two
                // indicators disagreeing, and "how far through" is what the
                // expanded panel is for.
                StatusGlyph(
                    status: run.status,
                    size: 11,
                    progress: nil,
                    blocked: run.isBlockedOnApproval,
                    isSuspended: model.isSuspended
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
                IdleMark(
                    animator: model.idleMarkAnimator,
                    height: 16,
                    isSuspended: model.isSuspended,
                    position: model.idleMarkPosition,
                    tint: model.idleMarkTint,
                    gradient: model.idleMarkGradient
                )
                .transition(.opacity)
            }
        }
        // Alignment on the ROW, not Spacers inside it. The mark is the one
        // thing in here that is not necessarily centred, and a child asking for
        // `maxWidth: .infinity` between two Spacers is three views bidding for
        // the same slack — SwiftUI splits it, and `leading` would not have come
        // out flush left.
        .frame(maxWidth: .infinity, alignment: restAlignment)
        // The shoulders are already off the table — see `contentInset`. What
        // is left is the air between the mark and the edge of the cutout.
        .padding(.horizontal, 4)
        .frame(height: restRowHeight)
        .padding(.bottom, isIdle ? 5 : 4)
        .transition(.opacity)
    }

    /// How tall the resting row is.
    ///
    /// Sized for a status glyph, except when what it is holding is the mark.
    /// A glyph is glanced at and a blinking mark is looked at, and at twelve
    /// points the second one was too small to be worth either.
    private var restRowHeight: CGFloat {
        isIdle && model.showsIdleMark ? 17 : 14
    }

    /// Centred, unless it is the idle mark and the user moved it.
    private var restAlignment: Alignment {
        isIdle && model.showsIdleMark ? model.idleMarkPosition.alignment : .center
    }

    /// Nothing to report: no runs on screen and nothing broken.
    private var isIdle: Bool {
        model.headline == nil && model.state.error == nil
    }

    // MARK: - Chrome

    /// Concave shoulders and convex bottom under a cutout, a plain pill
    /// otherwise. `IslandShape` carries the argument for the shoulders.
    private var shape: IslandShape {
        IslandShape(
            hasNotch: hasNotch,
            shoulder: hasNotch ? NotchGeometry.Width.shoulder : 0,
            bottomRadius: hasNotch ? 18 : 14,
            pillRadius: 14
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
                        IdleMark(
                            animator: model.idleMarkAnimator,
                            height: 13,
                            isSuspended: model.isSuspended,
                            isAttentive: true,
                            position: model.idleMarkPosition,
                            tint: model.idleMarkTint,
                            gradient: model.idleMarkGradient
                        )
                        .frame(width: 18)
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
                        isSuspended: model.isSuspended,
                        onOpen: onOpen,
                        onDismiss: onDismiss
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
            // Scrolls once it outgrows the window, and only then.
            //
            // The canvas is a fixed height and never grows (see
            // `NotchMath.canvasSize`), but the runs under it are not: a
            // Terraform plan adds up to a dozen rows to its job, and two
            // pipelines that each plan two environments ran the panel off the
            // bottom of the window — rows drawn on top of each other and the
            // footer pushed out of reach. Under the root's vertical
            // `fixedSize` this scroll view is proposed no height, so it reports
            // its content's own and `maxHeight` only ever *caps* it: a panel
            // that fits is exactly as tall as it was, and one that does not
            // stops at the window's edge and scrolls.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.expandedDetail) { run in
                        JobDetail(
                            run: run,
                            showActor: model.showsMultipleActors,
                            isSuspended: model.isSuspended,
                            showsPlanDetail: planCount <= 1,
                            onOpen: onOpen,
                            onDismiss: onDismiss
                        )
                            .transition(
                                .asymmetric(
                                    insertion: .move(edge: .top).combined(with: .opacity),
                                    removal: .opacity
                                )
                            )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: detailHeightLimit)

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

    /// Plans across every run the panel is drawing.
    ///
    /// One plan opens straight onto its resource list, the way it always
    /// has. More than one — two pipelines, or `staging` and `staging-dr` in
    /// the same one — start as a single line of counts each, so the panel
    /// answers "what is each of these going to do" at a glance and the rows
    /// behind any one of them are a click away instead of all of them at
    /// once.
    private var planCount: Int {
        model.expandedDetail.reduce(0) { total, run in
            total + run.jobList.reduce(0) { $0 + $1.terraformPlans.count }
        }
    }

    /// The tallest the run list may draw before it scrolls: the window,
    /// minus everything else the expanded island stacks above and below it.
    ///
    /// The pill above keeps its own fixed row height (`RunLine`, `noticeRow`)
    /// so it is counted rather than measured; `chrome` is the two hairlines,
    /// the panel's top padding, the footer, and room for the island's own
    /// shadow under its bottom edge. Unbounded until the controller has
    /// placed the window, which it does before the island can be hovered.
    private var detailHeightLimit: CGFloat {
        guard model.canvasHeight > 0 else { return .infinity }
        let band = hasNotch ? notchHeight : 0
        let pill: CGFloat
        if model.state.error != nil || model.collapsedRuns.isEmpty {
            pill = 32
        } else {
            pill = CGFloat(model.collapsedRuns.count) * 33
                + (model.hiddenRunCount > 0 ? 18 : 0)
        }
        let chrome: CGFloat = 72
        return max(model.canvasHeight - band - pill - chrome, 120)
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
    /// How many steps a job draws individually before the bar fills
    /// proportionally instead.
    ///
    /// It used to be a width budget: twenty-four dots at 7pt plus 3pt of air is
    /// 240pt, which was what fitted. The bar is 132pt whatever it holds, so
    /// this is now purely about legibility — twenty-four segments across 132pt
    /// leaves each one about 4.5pt wide, and much under that a segment stops
    /// being a thing you can see the colour of.
    static let stepDotLimit = 24

    let run: WorkflowRun
    var showActor: Bool = false
    /// True while the display is asleep, so the glyph can stop its animation.
    var isSuspended: Bool = false
    /// Whether a plan opens onto its resource list or starts as one line of
    /// counts. See `IslandView.planCount`.
    var showsPlanDetail: Bool = true
    var onOpen: (WorkflowRun) -> Void = { _ in }
    var onDismiss: (WorkflowRun) -> Void = { _ in }

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                StatusGlyph(
                    status: run.status,
                    size: 10,
                    progress: run.isActive ? run.progress : nil,
                    blocked: run.isBlockedOnApproval,
                    isSuspended: isSuspended
                )
                // No repository name here.
                //
                // The pill prints it sixteen points above this row and never
                // scrolls away, so a second copy bought nothing and cost the
                // one line the panel has for saying which commit this is. What
                // stands in its place — the run number, the branch, the wall
                // time — is what somebody reads *after* they already know which
                // repo broke.
                Text("#\(run.runNumber)")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.80))
                if let branch = run.headBranch {
                    Text(branch)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("Branch this run was started from")
                }
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
                // How long the whole run took, next to the jobs it is the sum
                // of. The pill carries this too, but the pill is gone the
                // moment somebody scrolls their eye down here.
                if let seconds = run.duration {
                    Text(IslandFormat.duration(seconds))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.42))
                        .monospacedDigit()
                        .help("Took \(IslandFormat.duration(seconds)) to run")
                }
                if run.isBlockedOnApproval {
                    ApprovalChip(run: run)
                }
                Button {
                    onDismiss(run)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .opacity(isHovering ? 1 : 0)
                .help("Hide this run — it stays on GitHub")
                .accessibilityLabel(Text("Hide this run"))
            }

            if run.jobList.isEmpty {
                Text(run.isActive ? "waiting for a runner…" : "no job detail")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }

            // One line per job: the mark, the name, a bar, the count, and the
            // one step worth naming.
            //
            // The steps used to carry a label each. On a real workflow that is
            // twenty of them — "Set up job", "Post Run actions/create-github-app-token@1b10c78…",
            // one line per action, SHA and all — and the expanded island became
            // a wall of text taller than the window it hangs from, which is
            // what a run's page on GitHub is already for. The bar keeps every
            // step's *state*, which is the part you cannot get at a glance
            // anywhere else; the one name worth printing is the step running
            // right now — or, on a job that broke, the step that broke it.
            ForEach(run.jobList) { job in
                jobRow(job)
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

            // The mirror of the line above, for a gate that has been answered.
            // Worth its own row rather than a tooltip: the run is drawn grey
            // and crossed out, and "why is this one not red" is a question
            // somebody will ask exactly once before they stop trusting the
            // colour. One line settles it.
            if let rejection = run.rejectionSummary {
                Text(rejectionLine(rejection))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
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

    /// One job, as a row.
    ///
    /// The failed one is the only row in the panel with a ground of its own.
    /// That is the whole point of it: three jobs drawn identically make the eye
    /// read all three to find the one that matters, and on a panel that exists
    /// to be glanced at, "read all three" is the cost being paid over and over.
    /// A rail and a wash of `failure` at a tenth take it to nothing. Nothing
    /// else in here is allowed a background, so there is never a second thing
    /// competing for the same glance.
    @ViewBuilder
    private func jobRow(_ job: Job) -> some View {
        // Only real breakage, never a rejection: `isFailure` deliberately
        // excludes `.rejected`, and a gate somebody turned down themselves is
        // not something to shout at them about. See `RunStatus.isFailure`.
        let blamed = job.status.isFailure

        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 7) {
                // `isSuspended` threaded through here as well, and it is the
                // row that most needed it: this glyph carries both of the
                // repeating animations the island permits itself — the
                // approval pulse and `ActivityRing`'s sweep — and a run has
                // one of these per job.
                StatusGlyph(
                    status: job.status,
                    size: 8,
                    blocked: job.isBlockedOnApproval,
                    isSuspended: isSuspended
                )
                Text(job.name)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(StatusStyle.color(for: job.status).opacity(0.95))
                    .frame(width: 96, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(job.name)

                StepBar(job: job, segmentCap: Self.stepDotLimit, isSuspended: isSuspended)

                if let note = jobNote(job) {
                    Text(note)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(blamed
                                         ? StatusPalette.failure.opacity(0.92)
                                         : .white.opacity(0.62))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(note)
                }

                Spacer(minLength: 0)
            }
            // The ground grows, the row does not.
            //
            // Padding the blamed row instead would push its glyph and its
            // name inward by the same amount, so the one row you are meant to
            // read fastest would be the one whose columns no longer line up
            // with the rows above it. Negative padding on the *background*
            // spends the width outward instead: every row's content stays on
            // the same two vertical rules, and only the paint bleeds. It is
            // the mirror of the positive inset the hover ground above uses
            // for the same reason.
            .background(
                ZStack(alignment: .leading) {
                    StatusPalette.failure.opacity(0.10)
                    Rectangle()
                        .fill(StatusPalette.failure)
                        .frame(width: 2)
                }
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .padding(.vertical, -2.5)
                .padding(.horizontal, -6)
                .opacity(blamed ? 1 : 0)
            )
            .animation(Motion.content, value: blamed)

            // Indented under the job's own name and step bar, not flush with
            // the glyph — a plan belongs to the row above it, and lining its
            // left edge up with `job.name` rather than `StatusGlyph` says so
            // without another label.
            //
            // Offset, not a plan id: a job's plans are fixed once parsed and
            // two environments can come out identical, so position is the
            // only identity they reliably have.
            ForEach(Array(job.terraformPlans.enumerated()), id: \.offset) { _, plan in
                TerraformPlanView(plan: plan, showsDetailByDefault: showsPlanDetail)
                    .padding(.leading, 15)
            }
        }
    }

    /// The one line of prose a job row earns: what is running, or what broke.
    ///
    /// A job with no steps at all is the case this exists for. GitHub returns
    /// steps only once a job starts, so a job that failed before it started —
    /// a bad `runs-on`, a missing secret, an unresolvable reusable workflow —
    /// arrives with an empty array, and the row used to print an em dash for
    /// it. The dash said nothing the colour had not already said. The job's own
    /// conclusion is a real answer, and saying where it came from is what stops
    /// somebody opening the browser to find out there was nothing to find.
    private func jobNote(_ job: Job) -> String? {
        if let running = job.steps.first(where: { $0.status == .inProgress }) {
            return running.name
        }
        guard job.status.isFailure else { return nil }
        if let broke = job.steps.first(where: { $0.status.isFailure }) {
            return broke.name
        }
        return "no step detail from GitHub"
    }

    /// The rejection, with the reviewer's comment when they left one.
    private func rejectionLine(_ summary: String) -> String {
        guard let comment = run.rejectionComment else { return summary }
        return "\(summary) — “\(comment)”"
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

/// A Terraform plan's shape, drawn the way `StepBar` draws a job's steps —
/// counts first, detail on request. Only ever shown for a job whose log
/// actually parsed into one; see `Job.terraformPlans`.
///
/// Colours are not a sixth hue: `.read` and `.moved` share `quiet` with
/// `cancelled` and `skipped` elsewhere in the island, on the same reasoning
/// `StatusStyle` already states — a narrow, fixed vocabulary is what keeps a
/// glance legible, and neither a data refresh nor a bare rename is news the
/// way a create, update, replace or destroy is.
struct TerraformPlanView: View {
    /// Rows drawn before the rest collapse into a count. The notch's canvas
    /// is a fixed height (`NotchMath.canvasSize`, shared across every run on
    /// screen) that does not grow to fit its content — an uncapped list from
    /// a real-sized plan pushes the panel's own footer, "updated Xs ago" and
    /// the Quit button, below the window's bottom edge, invisible and
    /// unclickable. The same reasoning `JobDetail.stepDotLimit` and
    /// `JobTrack.barLimit` already apply to a job's own steps, one level in.
    static let rowLimit = 8

    let plan: TerraformPlanSummary
    /// Whether the resource list starts open. Decided by the panel, not the
    /// plan: see `IslandView.planCount`.
    var showsDetailByDefault: Bool = true

    @State private var expandedAddresses: Set<String> = []
    /// `nil` until somebody clicks the counts line, and only then does it
    /// outrank `showsDetailByDefault` — so a plan nobody touched still
    /// follows the panel when a second plan arrives and the default flips.
    @State private var detailToggle: Bool?

    private var showsDetail: Bool { detailToggle ?? showsDetailByDefault }

    /// Anything behind the counts line worth opening it for.
    private var hasDetail: Bool {
        !plan.resources.isEmpty || !plan.outputChanges.isEmpty
    }

    /// The rows actually drawn when there are more than fit — riskiest
    /// first, so a destroy or a forced replacement is never one of the ones
    /// left in the overflow count while five untouched creates get the
    /// space instead.
    private var shownResources: [TerraformPlanSummary.ResourceChange] {
        guard plan.resources.count > Self.rowLimit else { return plan.resources }
        let priority: [TerraformPlanSummary.ResourceChange.Category] = [
            .destroy, .replace, .update, .create, .moved, .read,
        ]
        return plan.resources
            .enumerated()
            .sorted { lhs, rhs in
                let left = priority.firstIndex(of: lhs.element.category) ?? priority.count
                let right = priority.firstIndex(of: rhs.element.category) ?? priority.count
                // Stable within a category: ties keep plan order rather than
                // whatever order `sorted` would otherwise leave them in.
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .prefix(Self.rowLimit)
            .map(\.element)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !plan.driftedAddresses.isEmpty {
                driftBanner
            }

            summaryLine

            if showsDetail {
                if !plan.resources.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(shownResources) { resource in
                            resourceRow(resource)
                        }
                        if plan.resources.count > Self.rowLimit {
                            Text("+\(plan.resources.count - Self.rowLimit) more — open on GitHub")
                                .font(.system(size: 8.5, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                    }
                    .transition(.opacity)
                }

                if !plan.outputChanges.isEmpty {
                    outputsBlock
                        .transition(.opacity)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Summary

    /// The plan's name when its job has more than one, its counts, and —
    /// when there is a list behind them — the chevron that opens it.
    @ViewBuilder
    private var summaryLine: some View {
        let line = HStack(spacing: 6) {
            if let label = plan.label {
                Text(label)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .leading)
                    .help(label)
            }
            counts
            if hasDetail {
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.3))
                    .rotationEffect(.degrees(showsDetail ? 90 : 0))
            }
            Spacer(minLength: 0)
        }

        // Only a line with something behind it takes the click. One without
        // — a no-op plan — lets it through to the run underneath, which opens
        // on GitHub the way it did before this line was tappable at all.
        if hasDetail {
            line
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(Motion.content) { detailToggle = !showsDetail }
                }
        } else {
            line
        }
    }

    @ViewBuilder
    private var counts: some View {
        if plan.isNoOpPlan {
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                Text("no changes")
                    .font(.system(size: 9.5, design: .monospaced))
            }
            .foregroundStyle(StatusPalette.success.opacity(0.85))
        } else {
            HStack(spacing: 10) {
                statChip(count: plan.toAdd, label: "to add", color: StatusPalette.success)
                statChip(count: plan.toChange, label: "to change", color: StatusPalette.running)
                statChip(count: plan.toReplace, label: "to replace", color: StatusPalette.approval)
                statChip(count: plan.toDestroy, label: "to destroy", color: StatusPalette.failure)
                if let unchanged = plan.unchangedCount, unchanged > 0 {
                    Text("\(unchanged) unchanged")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
    }

    @ViewBuilder
    private func statChip(count: Int, label: String, color: Color) -> some View {
        if count > 0 {
            HStack(spacing: 3) {
                Text("\(count)")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                Text(label)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .foregroundStyle(color.opacity(0.95))
        }
    }

    // MARK: Drift

    private var driftBanner: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8))
            Text("drift: " + plan.driftedAddresses.joined(separator: ", "))
                .font(.system(size: 9, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.tail)
        }
        // `.approval`, not `.fault` — drift is real news about the
        // infrastructure, not Runway reporting a problem with itself, which
        // is the distinction `StatusPalette.fault`'s own doc comment draws.
        .foregroundStyle(StatusPalette.approval.opacity(0.9))
        .padding(.vertical, 2)
    }

    // MARK: Resources

    @ViewBuilder
    private func resourceRow(_ resource: TerraformPlanSummary.ResourceChange) -> some View {
        let isExpanded = expandedAddresses.contains(resource.address)
        let hasDetail = !resource.attributes.isEmpty || resource.movedFrom != nil

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(symbol(for: resource.category))
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(color(for: resource.category))
                    .frame(width: 12)
                Text(resource.address)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if hasDetail {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white.opacity(0.3))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard hasDetail else { return }
                withAnimation(Motion.content) {
                    if isExpanded { expandedAddresses.remove(resource.address) }
                    else { expandedAddresses.insert(resource.address) }
                }
            }
            .help(resource.actionReason ?? resource.category.rawValue)

            if isExpanded {
                VStack(alignment: .leading, spacing: 1) {
                    if let movedFrom = resource.movedFrom {
                        Text("moved from \(movedFrom)")
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    ForEach(resource.attributes, id: \.key) { attribute in
                        attributeRow(attribute)
                    }
                }
                .padding(.leading, 18)
                .transition(.opacity)
            }
        }
    }

    private func attributeRow(_ attribute: TerraformPlanSummary.AttributeDiff) -> some View {
        HStack(spacing: 5) {
            Text(attribute.key)
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
            if let before = attribute.before {
                // `.strikethrough` before `.foregroundStyle`: it is one of
                // `Text`'s own concatenation modifiers and only exists on
                // `Text` itself, while `.foregroundStyle` returns `some View`
                // — reversing the order would not compile.
                Text(before)
                    .font(.system(size: 8.5, design: .monospaced))
                    .strikethrough(attribute.after != nil, color: .white.opacity(0.25))
                    .foregroundStyle(.white.opacity(0.45))
                Text("→")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.25))
            }
            if let after = attribute.after {
                Text(after)
                    .font(.system(size: 8.5, design: .monospaced))
                    .italic(attribute.isUnknown || attribute.isSensitive)
                    .foregroundStyle(
                        .white.opacity(attribute.isUnknown || attribute.isSensitive ? 0.5 : 0.85)
                    )
            }
            if attribute.forcesReplacement {
                Text("forces replacement")
                    .font(.system(size: 7.5, design: .monospaced))
                    .foregroundStyle(StatusPalette.approval.opacity(0.8))
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
    }

    // MARK: Outputs

    private var outputsBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("outputs")
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
                .textCase(.uppercase)
            ForEach(plan.outputChanges, id: \.name) { output in
                HStack(spacing: 5) {
                    Text(output.name)
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                    if let before = output.before {
                        Text(before)
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                        Text("→")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.25))
                    }
                    if let after = output.after {
                        Text(after)
                            .font(.system(size: 8.5, design: .monospaced))
                            .italic(output.isUnknown)
                            .foregroundStyle(.white.opacity(output.isUnknown ? 0.5 : 0.85))
                    }
                }
                .lineLimit(1)
            }
        }
        .padding(.top, 2)
    }

    // MARK: Vocabulary

    private func symbol(for category: TerraformPlanSummary.ResourceChange.Category) -> String {
        switch category {
        case .create: return "+"
        case .update: return "~"
        case .replace: return "±"
        case .destroy: return "−"
        case .read: return "»"
        case .moved: return "→"
        }
    }

    private func color(for category: TerraformPlanSummary.ResourceChange.Category) -> Color {
        switch category {
        case .create: return StatusPalette.success
        case .update: return StatusPalette.running
        case .replace: return StatusPalette.approval
        case .destroy: return StatusPalette.failure
        case .read, .moved: return StatusPalette.quiet
        }
    }
}

/// One run as a single compact line, for the collapsed island.
struct RunLine: View {
    let run: WorkflowRun
    let now: Date
    var showActor: Bool = false
    /// True while the display is asleep, so the glyph can stop its animation.
    var isSuspended: Bool = false
    let onOpen: (WorkflowRun) -> Void
    var onDismiss: (WorkflowRun) -> Void = { _ in }

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            StatusGlyph(
                status: run.status,
                size: 13,
                progress: run.isActive ? run.progress : nil,
                blocked: run.isBlockedOnApproval,
                isSuspended: isSuspended
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
            } else if let job = run.firstRunningJob {
                Text(runningLabel(job))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.66))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(runningHelp(job))
            }

            Spacer(minLength: 4)

            timing

            // Reserved whether or not it is drawn. Appearing on hover is what
            // keeps a destructive-looking control off a pill that is mostly
            // read at a glance; reserving the width is what stops the row
            // reflowing — and the duration next to it jumping — the instant the
            // pointer arrives.
            openControl
                .frame(width: 13)
                .opacity(isHovering ? 1 : 0)

            dismissControl
                .frame(width: 15)
                .opacity(isHovering ? 1 : 0)
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

    /// How long this run has been parked, at the grain the island actually
    /// redraws it.
    ///
    /// Minutes, not `M:SS`. `IslandModel.tickSeconds` drops a blocked island to
    /// a 15-second cadence, and the reason it gives is that a parked run "does
    /// not count anything" — which was true of everything else on the row and
    /// never of this label. It counted seconds against a clock that moves four
    /// times a minute, so the number jumped 0s → 15s → 30s → 45s → 1:00, with
    /// `.numericText()` rolling the digits through each fifteen-second leap.
    ///
    /// Making the label coarse is the half to change. The alternative is a
    /// one-second ticker for a run waiting on a person, which is the 3,600
    /// wakeups an hour that `tickSeconds` exists to refuse — and this is the
    /// state the island sits in longest, so it is the worst place to spend
    /// them. Nobody reads a deployment gate to the second anyway; hours are
    /// what these actually run to, and `M:SS` had no way to say one.
    private var waitingLabel: String {
        guard let since = run.updatedAt ?? run.startedAt else { return "—" }
        return IslandFormat.waited(now.timeIntervalSince(since))
    }

    /// What is happening right now, at the finest grain the payload allows.
    ///
    /// The job's name is the coarse answer and was all this row printed. Once
    /// the jobs endpoint has sent steps, the step actually executing is the
    /// better half of the sentence — "terraform-apply" says which part of the
    /// workflow is busy, "Run terraform apply" says what the machine is doing,
    /// and the second one is the line people were opening the browser to read.
    private func runningLabel(_ job: Job) -> String {
        job.firstRunningStep?.name ?? job.name
    }

    private func runningHelp(_ job: Job) -> String {
        guard let step = job.firstRunningStep else { return "Running \(job.name)" }
        return "\(job.name) › \(step.name)"
    }

    /// The row opens the run in a browser; this is what says so.
    ///
    /// A tooltip used to be the only thing that told you, and it told you by
    /// painting a box over three of the five lines you were reading, on hover,
    /// which is exactly when you were reading them. An arrow in the row's own
    /// trailing edge says the same thing in thirteen points and covers nothing.
    /// The `.help` text stays for VoiceOver and for the pointer that lingers;
    /// it is just no longer the only channel.
    ///
    /// Not a button. The whole row is already the click target, and a second
    /// one inside it would be two hit regions doing the same job — with the
    /// inner one stealing clicks from the outer. Width is reserved like the
    /// cross beside it, for the same reason.
    private var openControl: some View {
        Image(systemName: "arrow.up.forward")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white.opacity(0.5))
            .frame(width: 13, height: 13)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Take this run off the island.
    ///
    /// A cross, not a bin. Nothing is deleted: the run is untouched on GitHub,
    /// which is what the help text says out loud, because a cross on a row of
    /// somebody's CI is exactly the control people are right to hesitate over.
    private var dismissControl: some View {
        Button {
            onDismiss(run)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 15, height: 15)
                .background(Circle().fill(Color.white.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Hide this run — it stays on GitHub")
        .accessibilityLabel(Text("Hide this run"))
    }

    private var helpText: String {
        // The rejection first. It is the one status where GitHub's own word for
        // the run and the true one disagree, so it is the one worth spelling
        // out rather than leaving to a grey glyph.
        if let rejection = run.rejectionSummary {
            let comment = run.rejectionComment.map { " — “\($0)”" } ?? ""
            return "\(run.repository) #\(run.runNumber) — \(rejection)\(comment)."
                + " Nothing failed. Click to open it on GitHub."
        }
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
