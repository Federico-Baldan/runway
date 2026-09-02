import SwiftUI

// MARK: - Palette

/// The island's colour vocabulary.
///
/// Fixed values rather than `.green` / `.red` / `.secondary`. The island is
/// drawn on an opaque black band under a notch, where the system semantic
/// colours are tuned for the opposite: they are picked against a window
/// background that adapts to appearance, and on black the standard red and
/// green sit far too dark while `.secondary` all but disappears. These are the
/// same hues lifted a step and desaturated a step, which is what keeps a
/// failure legible at nine points without turning the whole notch into a
/// warning light.
enum StatusPalette {
    /// Something is moving.
    static let running = Color(red: 0.36, green: 0.64, blue: 1.00)
    /// It passed.
    static let success = Color(red: 0.22, green: 0.85, blue: 0.55)
    /// It broke.
    static let failure = Color(red: 1.00, green: 0.40, blue: 0.44)
    /// A person is the blocker — the one state you can do something about.
    static let approval = Color(red: 1.00, green: 0.74, blue: 0.28)
    /// Cancelled, skipped, neutral: real states, but not news.
    static let quiet = Color(white: 0.60)
    /// Something is wrong with Runway itself, not with your CI.
    static let fault = Color(red: 1.00, green: 0.62, blue: 0.24)

    /// Where a run is going, as opposed to how it is doing.
    ///
    /// Deliberately outside the status hues. An environment is not a state:
    /// a production deploy can be running, passing or broken, and the two
    /// facts have to be readable at the same time on the same 32pt row. Every
    /// status colour here is warm-or-primary — blue, green, red, amber — so
    /// the environments take the half of the wheel none of them use, and a
    /// violet chip next to a green disc can never be read as a fourth kind of
    /// outcome.
    static func environment(_ tier: DeployTier) -> Color {
        switch tier {
        // The one that costs something to get wrong, so the one with a colour
        // of its own that nothing else in the app uses.
        case .production: return Color(red: 0.78, green: 0.58, blue: 1.00)
        case .staging: return Color(red: 0.36, green: 0.82, blue: 0.84)
        // A test deploy is not news, and is drawn like it.
        case .testing, .unknown: return Color(white: 0.66)
        }
    }

    /// A two-stop gradient for a filled disc, so a 10pt circle still has a
    /// direction to it instead of reading as a flat sticker.
    static func fill(_ colour: Color) -> LinearGradient {
        LinearGradient(
            colors: [colour, colour.opacity(0.74)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// Colour + glyph vocabulary shared by the pill and the expanded rows.
enum StatusStyle {
    static func color(for status: RunStatus) -> Color {
        if status.isAwaitingApproval { return StatusPalette.approval }
        if status.isActive { return StatusPalette.running }
        if status.isFailure { return StatusPalette.failure }
        switch status {
        case .success: return StatusPalette.success
        default: return StatusPalette.quiet
        }
    }

    /// SF Symbol for a run / job / step status.
    ///
    /// Only the menu bar item still speaks in SF Symbols — it draws into an
    /// `NSImage` and inherits the system's optical sizing for the menu bar,
    /// which is exactly what those symbols are tuned for. The island draws its
    /// own marks instead; see `StatusGlyph` for why.
    static func symbol(for status: RunStatus) -> String {
        if status.isAwaitingApproval { return "exclamationmark.circle.fill" }
        if status.isActive { return "circle.dotted" }
        switch status {
        case .success: return "checkmark.circle.fill"
        case .failure, .startupFailure: return "xmark.circle.fill"
        case .timedOut: return "clock.badge.xmark"
        case .cancelled: return "slash.circle"
        case .skipped: return "arrow.right.circle"
        case .neutral, .stale: return "minus.circle"
        default: return "circle"
        }
    }

    static func color(for mood: IslandMood) -> Color {
        switch mood {
        case .running: return StatusPalette.running
        case .failed: return StatusPalette.failure
        case .success: return StatusPalette.success
        case .approval: return StatusPalette.approval
        case .error: return StatusPalette.fault
        case .idle: return StatusPalette.quiet
        }
    }
}

// MARK: - Marks

/// The stroke inside a status disc, in a unit square.
///
/// Drawn rather than pulled from SF Symbols, for two reasons that only show up
/// at the size the island works at. Optically, `checkmark.circle.fill` and
/// `hand.raised.circle` are drawn by different hands at different weights: side
/// by side at nine points the run states look like they came from two apps.
/// Mechanically, a symbol is a font lookup that can silently render nothing if
/// the name was renamed or is newer than the running system, and a status app
/// whose failure glyph is invisible is worse than one with no glyph at all.
///
/// A path also gets something a symbol cannot: `trim`, which is what lets the
/// mark *draw itself in* when a run changes state.
struct StatusMarkShape: Shape {
    enum Kind {
        case check
        case cross
        case slash
        case chevron
        case dash
        case clock
        /// The upright of an exclamation mark. Its dot is a separate circle —
        /// a trim animation across a two-subpath glyph draws the dot as a
        /// smear, and the point of the dot is that it lands.
        case bang
    }

    let kind: Kind

    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }

        var path = Path()
        switch kind {
        case .check:
            path.move(to: point(0.26, 0.52))
            path.addLine(to: point(0.43, 0.70))
            path.addLine(to: point(0.75, 0.31))
        case .cross:
            path.move(to: point(0.32, 0.32))
            path.addLine(to: point(0.68, 0.68))
            path.move(to: point(0.68, 0.32))
            path.addLine(to: point(0.32, 0.68))
        case .slash:
            path.move(to: point(0.30, 0.70))
            path.addLine(to: point(0.70, 0.30))
        case .chevron:
            path.move(to: point(0.41, 0.29))
            path.addLine(to: point(0.63, 0.50))
            path.addLine(to: point(0.41, 0.71))
        case .dash:
            path.move(to: point(0.29, 0.50))
            path.addLine(to: point(0.71, 0.50))
        case .clock:
            path.move(to: point(0.50, 0.27))
            path.addLine(to: point(0.50, 0.52))
            path.addLine(to: point(0.69, 0.63))
        case .bang:
            path.move(to: point(0.50, 0.27))
            path.addLine(to: point(0.50, 0.55))
        }
        return path
    }
}

// MARK: - The status glyph

/// One run, job or step's state as a single mark.
///
/// The grammar is deliberately narrow, so it can be read without a legend:
///
///  * **Solid disc** — settled. It happened; it will not change.
///  * **Ring** — in flight. The ring sweeps, and fills clockwise as the run's
///    steps complete, so the same mark answers "is it alive" and "how far in".
///  * **Amber, with an exclamation** — parked on a person. Never green, never
///    red: nothing has passed and nothing has broken, somebody has to click.
struct StatusGlyph: View {
    let status: RunStatus
    var size: CGFloat = 12
    /// Fraction of the run's steps that have settled, for the determinate arc.
    /// `nil` leaves the ring indeterminate.
    var progress: Double? = nil
    /// Set when the run is blocked on an approval, which outranks the status:
    /// a run can say `in_progress` while one of its jobs waits on a reviewer.
    var blocked: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false
    @State private var pulse = false

    var body: some View {
        content
            .frame(width: size, height: size)
            .scaleEffect(pulse ? 1.07 : 1)
            .animation(pulseAnimation, value: pulse)
            .onAppear { begin() }
            .onChange(of: status) { _, _ in redraw() }
            .onChange(of: blocked) { _, _ in redraw() }
            .accessibilityLabel(Text(accessibilityLabel))
    }

    // MARK: Composition

    @ViewBuilder
    private var content: some View {
        if blocked || status.isAwaitingApproval {
            approval
        } else if status.isActive {
            ActivityRing(
                colour: tint,
                progress: progress,
                size: size,
                isMoving: status == .inProgress
            )
        } else if let mark = solidMark {
            disc(mark)
        } else {
            outline(outlineMark)
        }
    }

    /// Settled and worth a solid disc.
    private var solidMark: StatusMarkShape.Kind? {
        switch status {
        case .success: return .check
        case .failure, .startupFailure: return .cross
        case .timedOut: return .clock
        case .cancelled: return .slash
        default: return nil
        }
    }

    /// Settled, but not news — drawn as an outline so it recedes.
    private var outlineMark: StatusMarkShape.Kind {
        status == .skipped ? .chevron : .dash
    }

    private func disc(_ kind: StatusMarkShape.Kind) -> some View {
        ZStack {
            Circle()
                .fill(StatusPalette.fill(tint))
                .shadow(color: tint.opacity(0.55), radius: size * 0.30)
            StatusMarkShape(kind: kind)
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(style: strokeStyle(0.16))
                // A real hole rather than a mark painted in the background
                // colour: the island is opaque under a notch and translucent
                // everywhere else, so "the background colour" is not one value.
                .blendMode(.destinationOut)
        }
        .compositingGroup()
    }

    private func outline(_ kind: StatusMarkShape.Kind) -> some View {
        ZStack {
            Circle().strokeBorder(tint.opacity(0.50), lineWidth: max(size * 0.10, 1))
            StatusMarkShape(kind: kind)
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(tint.opacity(0.85), style: strokeStyle(0.13))
        }
    }

    /// The one state the island wants you to look at.
    private var approval: some View {
        ZStack {
            Circle()
                .fill(StatusPalette.approval.opacity(0.22))
                .blur(radius: size * 0.22)
                .scaleEffect(1.6)

            ZStack {
                Circle().fill(StatusPalette.fill(StatusPalette.approval))
                StatusMarkShape(kind: .bang)
                    .trim(from: 0, to: drawn ? 1 : 0)
                    .stroke(style: strokeStyle(0.17))
                    .blendMode(.destinationOut)
                Circle()
                    .frame(width: size * 0.17, height: size * 0.17)
                    .offset(y: size * 0.22)
                    .scaleEffect(drawn ? 1 : 0)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
            .shadow(color: StatusPalette.approval.opacity(0.6), radius: size * 0.34)
        }
    }

    private func strokeStyle(_ ratio: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: max(size * ratio, 1.2), lineCap: .round, lineJoin: .round)
    }

    // MARK: Motion

    private var tint: Color { StatusStyle.color(for: status) }

    /// Only the approval glyph breathes, and only while it is on screen.
    ///
    /// A `repeatForever` animation holds the display link open for as long as
    /// the view lives, which is the one recurring cost this app has spent a lot
    /// of effort not paying. It is worth it here and nowhere else: an approval
    /// is the single state where the island is asking for something back.
    private var pulseAnimation: Animation? {
        guard pulse, !reduceMotion else { return nil }
        return .easeInOut(duration: 1.5).repeatForever(autoreverses: true)
    }

    private func begin() {
        let isBlocked = blocked || status.isAwaitingApproval
        guard !reduceMotion else {
            drawn = true
            return
        }
        withAnimation(.easeOut(duration: 0.42).delay(0.04)) { drawn = true }
        pulse = isBlocked
    }

    /// Redraw the mark when the state under it changes, so a run going from
    /// running to passed *strikes* the check rather than swapping one static
    /// glyph for another.
    ///
    /// The hop is load-bearing. Setting `drawn` to false and then to true in
    /// the same update coalesces into no change at all: SwiftUI only ever sees
    /// the final value, the trim stays at 1, and the animation this exists for
    /// silently does not happen. Yielding to the next turn of the main actor
    /// lets the first value commit, so there is something to animate away from.
    private func redraw() {
        let isBlocked = blocked || status.isAwaitingApproval
        pulse = isBlocked && !reduceMotion
        guard !reduceMotion else {
            drawn = true
            return
        }
        drawn = false
        Task { @MainActor in
            withAnimation(.easeOut(duration: 0.42)) { drawn = true }
        }
    }

    private var accessibilityLabel: String {
        if blocked || status.isAwaitingApproval { return "waiting for approval" }
        return status.label
    }
}

/// The in-flight ring: a track, a sweeping head, and — once the run's steps are
/// known — an arc that fills clockwise as they settle.
///
/// The head keeps moving even when the arc does not, which is the whole reason
/// it is separate: a job stuck for four minutes on one step has a frozen
/// progress arc, and a frozen glyph reads as a hung app rather than a slow test.
struct ActivityRing: View {
    var colour: Color
    var progress: Double? = nil
    var size: CGFloat
    var isMoving: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    private var lineWidth: CGFloat { max(size * 0.13, 1.3) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(colour.opacity(0.20), lineWidth: lineWidth)

            if let progress, progress > 0.005 {
                Circle()
                    .trim(from: 0, to: min(max(progress, 0), 1))
                    .stroke(colour.opacity(0.9),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(duration: 0.55, bounce: 0.12), value: progress)
            }

            // The head. Its LENGTH says whether work is happening — a long arc
            // for a running job, a bare tick for one still queued — while its
            // speed stays fixed. Varying the duration instead looked better
            // and did not work: the animation is bound to `spin`, which only
            // ever changes once, so a ring that appeared while the job was
            // queued kept the slow sweep for the rest of the run.
            Circle()
                .trim(from: 0, to: isMoving ? 0.24 : 0.07)
                .stroke(colour.opacity(isMoving ? 1 : 0.7),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(spin ? 270 : -90))
                .animation(sweep, value: spin)
        }
        .onAppear { spin = !reduceMotion }
    }

    /// A full turn, from -90° to 270°.
    private var sweep: Animation? {
        guard !reduceMotion else { return nil }
        return .linear(duration: 1.2).repeatForever(autoreverses: false)
    }
}

// MARK: - Chips

/// Who triggered a run, as a compact chip.
///
/// Only drawn when more than one person's runs are on screen — with a single
/// actor the label is the same on every row and just costs width.
struct ActorChip: View {
    let run: WorkflowRun
    var compact: Bool = false

    private var login: String? {
        run.triggeringActor?.login ?? run.actor?.login
    }

    var body: some View {
        if let login {
            HStack(spacing: 3) {
                Image(systemName: run.isRerun ? "arrow.clockwise" : "person.fill")
                    .font(.system(size: compact ? 7 : 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.40))
                Text(login)
                    .font(.system(size: compact ? 9 : 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                Capsule().fill(Color.white.opacity(0.07))
            )
            .help(helpText(login))
        }
    }

    private func helpText(_ login: String) -> String {
        guard run.isRerun, let original = run.actor?.login, original != login else {
            return "Triggered by \(login)"
        }
        return "Pushed by \(original), re-run by \(login) (attempt \(run.runAttempt))"
    }
}

/// "waiting for you · production", in amber, on any run parked on a person.
///
/// The wording is `WorkflowRun.approvalSummary`, shared with the notification,
/// so the banner and the island can never say two different things about the
/// same run.
struct ApprovalChip: View {
    let run: WorkflowRun
    var compact: Bool = false

    private var isMine: Bool { run.awaitsMyApproval }

    var body: some View {
        if let summary = run.approvalSummary {
            HStack(spacing: 4) {
                Image(systemName: isMine ? "person.badge.key.fill" : "clock.badge.checkmark")
                    .font(.system(size: compact ? 8 : 9, weight: .semibold))
                Text(summary)
                    .font(.system(size: compact ? 9 : 10, weight: isMine ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(StatusPalette.approval.opacity(isMine ? 1 : 0.8))
            .padding(.horizontal, compact ? 5 : 7)
            .padding(.vertical, compact ? 1.5 : 2.5)
            // Steady, not breathing. An approval waiting on you already gets
            // the brighter fill, the bolder weight and a Notification Centre
            // banner; a border pulsing forever underneath all that was the
            // island nagging, and it kept a repeating animation alive for the
            // hour a blocked run can sit there.
            .background(
                Capsule()
                    .fill(StatusPalette.approval.opacity(isMine ? 0.18 : 0.10))
                    .overlay(
                        Capsule().strokeBorder(
                            StatusPalette.approval.opacity(isMine ? 0.45 : 0.22),
                            lineWidth: 1
                        )
                    )
            )
            .help(isMine
                  ? "GitHub says you can approve this. Click the row to open the run."
                  : "This run is waiting on somebody else.")
        }
    }
}

/// Where a run is deploying — `production`, `PreProd`, `staging`.
///
/// Two treatments, and the difference between them is the whole reason this
/// chip is trustworthy. **Filled** means GitHub named the environment itself,
/// through the pending-deployment gate the run is parked on. **Outlined** means
/// Runway read a name — a job, the workflow, the branch — and drew a
/// conclusion. Both say what they are in the tooltip, because "this is going to
/// production" is a sentence a status app had better not be casually wrong
/// about. `DeployClassifier` explains what it will and will not guess from.
struct EnvironmentChip: View {
    /// Two, because this appears where the island has two width budgets: the
    /// resting badge under a cutout, and a run row.
    enum Size {
        case micro
        case compact
    }

    let target: DeployTarget
    var size: Size = .regular

    private var colour: Color { StatusPalette.environment(target.tier) }

    private var fontSize: CGFloat {
        size == .micro ? 7.5 : 9
    }

    /// Enough for `production` and `preproduction`, and a truncation for the
    /// team that named an environment after a region and a customer.
    private var maximumWidth: CGFloat {
        size == .micro ? 62 : 88
    }

    var body: some View {
        Text(target.name)
            .font(.system(size: fontSize, weight: target.tier == .production ? .semibold : .medium,
                          design: .monospaced))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: maximumWidth)
            .foregroundStyle(colour.opacity(target.isConfirmed ? 1 : 0.78))
            .padding(.horizontal, size == .micro ? 4 : 5)
            .padding(.vertical, size == .micro ? 0.5 : 1.5)
            .background(
                Capsule()
                    .fill(colour.opacity(target.isConfirmed ? 0.18 : 0))
                    .overlay(
                        Capsule().strokeBorder(
                            colour.opacity(target.isConfirmed ? 0.45 : 0.26),
                            lineWidth: 1
                        )
                    )
            )
            .help(target.provenance)
            .accessibilityLabel(Text("deploys to \(target.name)"))
    }
}

// MARK: - Job and step tracks

/// The run's jobs as a segmented track — one segment per step, one group per
/// job, in reading order.
///
/// GitLab drew stages, each holding jobs. GitHub's equivalent nesting is one
/// level down — a run holds **jobs**, each holding **steps** — so a job takes
/// the place of a stage here and a step takes the place of a job.
///
/// Segments rather than the dots this replaced. A dot per step with three
/// points of air around it spent most of its width on the gaps, and at four
/// jobs of six steps the strip pushed the elapsed time off the end of the pill.
/// A 4pt segment carries the same colour in a third of the room, and abutting
/// them turns the strip into something a progress bar's worth of meaning can be
/// read off in one glance.
struct JobTrack: View {
    let run: WorkflowRun
    /// Compact drops the trailing job name, for the collapsed pill.
    var compact: Bool = false

    var body: some View {
        HStack(spacing: compact ? 5 : 7) {
            ForEach(Array(run.jobList.enumerated()), id: \.offset) { _, job in
                HStack(spacing: 1.5) {
                    // A job whose steps have not arrived yet still deserves a
                    // segment: the jobs endpoint returns steps only once the
                    // job starts, and an empty row reads as a rendering bug.
                    if job.steps.isEmpty {
                        StepSegment(status: job.status, name: job.name, job: job.name)
                    } else {
                        ForEach(job.steps) { step in
                            StepSegment(status: step.status, name: step.name, job: job.name)
                        }
                    }
                }
                .transition(.scale(scale: 0.4, anchor: .leading).combined(with: .opacity))
            }

            if !compact, let running = runningLabel {
                Text(running)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(StatusPalette.quiet)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 1)
            }
        }
        .frame(height: 10)
    }

    private var runningLabel: String? {
        let names = run.runningJobs.map(\.name)
        guard !names.isEmpty else { return nil }
        return names.joined(separator: ", ")
    }
}

/// One step, as a segment of the track.
struct StepSegment: View {
    let status: RunStatus
    let name: String
    let job: String

    private var isRunning: Bool { status == .inProgress }
    /// Not-yet-started work is a dim rail rather than a filled segment.
    private var isPending: Bool {
        status == .queued || status == .pending || status == .requested
    }

    private var colour: Color { StatusStyle.color(for: status) }
    private var width: CGFloat { isRunning ? 7 : 4.5 }

    var body: some View {
        // A segment says its state with colour and width, and stops there.
        //
        // It used to carry a white highlight travelling back and forth inside
        // it and a coloured glow around it — per step, on every job, forever.
        // Four jobs of twenty steps is eighty of them animating at once behind
        // a pill you are meant to glance at, and the one thing genuinely worth
        // seeing move — the run's own ring — was competing with all of it. The
        // running segment is still the wide one, which is what the eye actually
        // lands on.
        Capsule(style: .continuous)
            .fill(isPending ? Color.white.opacity(0.16) : colour.opacity(0.92))
            .frame(width: width, height: 3.5)
            .animation(Motion.content, value: status)
            .help("\(job) › \(name): \(status.label)")
    }
}

/// One step as a dot, for the expanded panel's per-job strip.
struct StepDot: View {
    let status: RunStatus
    let name: String
    let job: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var isRunning: Bool { status == .inProgress }
    private var isPending: Bool {
        status == .queued || status == .pending || status == .requested
    }
    private var isBlocked: Bool { status.isAwaitingApproval }
    private var colour: Color { StatusStyle.color(for: status) }

    var body: some View {
        ZStack {
            if isPending {
                Circle().strokeBorder(colour.opacity(0.55), lineWidth: 1.4)
            } else {
                Circle().fill(StatusPalette.fill(colour))
            }
        }
        .frame(width: 7, height: 7)
        .scaleEffect(pulse ? 1.35 : 1)
        .opacity(pulse ? 0.5 : 1)
        .animation(pulseAnimation, value: pulse)
        .onAppear { pulse = shouldPulse }
        .onChange(of: status) { _, _ in pulse = shouldPulse }
        .help("\(job) › \(name): \(status.label)")
    }

    private var shouldPulse: Bool { (isRunning || isBlocked) && !reduceMotion }

    private var pulseAnimation: Animation? {
        guard shouldPulse else { return nil }
        return .easeInOut(duration: isBlocked ? 1.2 : 0.65).repeatForever(autoreverses: true)
    }
}
