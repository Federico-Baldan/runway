import Foundation
import Observation
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
        // A rejection lands in the quiet grey with `cancelled` and `skipped`,
        // and not — the temptation — in the approval amber it came out of.
        // Amber is the colour of a question still open; this one has been
        // answered, by the person looking at the island, on purpose. Anything
        // warmer would keep pulling the eye back to a decision already made,
        // which is the complaint that put `.rejected` in the app to begin with.
        // It gets its own *mark* instead — see `outlineMark`.
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
        // The same cross, hollow. Whatever was going to happen did not happen —
        // but a filled disc in the menu bar is the app raising its voice, and a
        // rejection is not something to raise your voice about.
        case .rejected: return "xmark.circle"
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
    /// True while the display is asleep, which stops both repeating animations
    /// below. See `ActivityRing.isStill` for why that matters.
    var isSuspended: Bool = false

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
            // A dark screen is not somebody to breathe at. The pulse is the one
            // `repeatForever` the island permits itself, and leaving it running
            // behind a closed lid is exactly the recurring wakeup the rest of
            // this app goes out of its way not to schedule.
            .onChange(of: isSuspended) { _, suspended in
                pulse = suspended ? false : (blocked || status.isAwaitingApproval) && !reduceMotion
            }
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
                isMoving: status == .inProgress,
                isSuspended: isSuspended
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
    ///
    /// `.rejected` keeps the cross, because something really did not go
    /// through and a dash would undersell that. Hollow and grey rather than a
    /// filled red disc is the entire distinction the state exists to draw: the
    /// deploy did not happen, and nobody needs to go and find out why.
    private var outlineMark: StatusMarkShape.Kind {
        switch status {
        case .skipped: return .chevron
        case .rejected: return .cross
        default: return .dash
        }
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
        pulse = isBlocked && !isSuspended
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
        pulse = isBlocked && !reduceMotion && !isSuspended
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

/// The in-flight ring: a track, a sweeping head trailing its own wake, and —
/// once the run's steps are known — an arc that fills clockwise as they settle.
///
/// The head keeps moving even when the arc does not, which is the whole reason
/// it is separate: a job stuck for four minutes on one step has a frozen
/// progress arc, and a frozen glyph reads as a hung app rather than a slow test.
struct ActivityRing: View {
    var colour: Color
    var progress: Double? = nil
    var size: CGFloat
    var isMoving: Bool = true
    /// True while the display is asleep. See `isStill`.
    var isSuspended: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

            // The head's angle is READ OFF THE CLOCK rather than animated
            // towards, and that is the whole of the fix for a sweep that
            // stuttered and then stopped.
            //
            // It used to be a `repeatForever` bound to a `@State` Bool flipped
            // once in `onAppear`, which makes the motion a one-shot latch.
            // Core Animation owns the turn from then on, and the moment it
            // loses that animation — the panel ordered out and back in, a
            // space switch, the layer re-established behind a resize — nothing
            // re-arms it: `spin` is already true, so no `onChange` fires and
            // no `onAppear` runs a second time. What is left on screen is the
            // frame the ring happened to be on, a still photograph of a
            // spinner sitting under a UI that carries on updating around it.
            // Reduce Motion had the same hole in the other direction, and
            // `IdleMark` had already been fixed for exactly that.
            //
            // A schedule cannot get into that state. The angle is a function
            // of the date it is handed, so a dropped frame stays a dropped
            // frame instead of becoming a phase error, there is no restart to
            // interrupt, and the turn wraps at 360° onto itself with no seam.
            // `paused:` is what stands the display link down — the same signal
            // as before, now covering Reduce Motion live rather than only at
            // launch. Reading a shared clock also puts every ring on screen in
            // phase, where each used to start from its own `onAppear`.
            TimelineView(.animation(minimumInterval: frameInterval, paused: isStill)) { context in
                comet.rotationEffect(.degrees(Self.sweepAngle(at: context.date)))
            }
        }
    }

    /// The head, with its own wake behind it.
    ///
    /// Its LENGTH says whether work is happening — a long tail for a running
    /// job, a bare stub for one still queued — while its speed stays fixed.
    /// Varying the duration instead looked better and did not work, and off a
    /// clock it cannot work at all: the phase is `elapsed / period`, so
    /// changing the period puts the head somewhere else on the circle in the
    /// same frame, and the sweep jumps every time a job starts running.
    ///
    /// The wake is an `AngularGradient` rather than a flat arc because at nine
    /// points a bare arc has no direction to it: it is a dash that jitters, and
    /// which way it is going is most of what the mark is for. A gradient
    /// running from transparent at the tail to solid at the head costs the same
    /// single stroke and answers that without another layer.
    private var comet: some View {
        ZStack {
            // `trim` starts at 3 o'clock and runs clockwise, and so does an
            // angular gradient's own angle, so the two line up with no
            // correction between them. The arc is then swung back by its whole
            // length, which puts its HEAD — rather than its tail — at 3
            // o'clock, where the head disc below is drawn.
            Circle()
                .trim(from: 0, to: tail)
                .stroke(
                    AngularGradient(
                        stops: [
                            .init(color: colour.opacity(0), location: 0),
                            .init(color: colour.opacity(0.34 * headOpacity), location: 0.62),
                            .init(color: colour.opacity(headOpacity), location: 1)
                        ],
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(Double(360 * tail))
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(Double(-360 * tail)))

            // The head itself, drawn rather than left to the stroke's round
            // cap. The gradient only reaches full strength in its last fraction
            // of a degree, and a wake whose brightest pixel is also its last
            // one reads as a tail with nothing on the end of it.
            Circle()
                .fill(colour.opacity(headOpacity))
                .frame(width: lineWidth, height: lineWidth)
                .offset(x: (size - lineWidth) / 2)
        }
    }

    /// How much of the circle the wake covers. A queued job gets a stub, so the
    /// ring can say "nothing is moving yet" without having to stop.
    private var tail: CGFloat { isMoving ? 0.58 : 0.12 }

    private var headOpacity: Double { isMoving ? 1 : 0.7 }

    /// Seconds for one full turn.
    private static let period: TimeInterval = 1.05

    /// Where the head is at a given instant, from 12 o'clock, clockwise.
    ///
    /// Modulo one turn rather than an angle that grows forever: the wrap is
    /// invisible because 360° is where it started, and a `Double` that has
    /// been counting degrees since the reference date loses precision it does
    /// not need to lose.
    private static func sweepAngle(at date: Date) -> Double {
        let turns = date.timeIntervalSinceReferenceDate / period
        return -90 + 360 * (turns - turns.rounded(.down))
    }

    /// Nothing to turn for: a dark screen, or somebody who asked for less
    /// motion. Pausing the schedule is what stops the wakeups — the cost the
    /// island stands every other repeating animation down to avoid.
    private var isStill: Bool { reduceMotion || isSuspended }

    /// How often the sweep asks to be redrawn, or `nil` for the display's own
    /// rate.
    ///
    /// `.animation` with no interval ticks at whatever the panel refreshes at,
    /// which on any recent Mac is 120 Hz — and it does so for the entire
    /// duration of every run on screen, which for CI is minutes at a stretch.
    /// That is the app's largest sustained cost while something is building,
    /// and it was the one repeating animation that had never heard of Low
    /// Power Mode. Everything else has: the poll drops to a 30-second floor,
    /// the idle mark drops to its lid-only vocabulary and sleeps after twenty
    /// seconds. A 9-point ring redrawing 120 times a second through all of it
    /// is ignoring an instruction the rest of the app takes seriously.
    ///
    /// Throttled rather than paused, because a *stopped* spinner is the one
    /// thing this ring must never be — see `sweepAngle(at:)` for the bug that
    /// cost. Fifteen frames a second on a mark this size is a slightly
    /// coarser turn, and reading the angle off the clock means the frames that
    /// are skipped stay skipped instead of becoming a phase error.
    private var frameInterval: Double? {
        PowerState.shared.isLowPower ? 1.0 / 15 : nil
    }
}

/// The system's Low Power Mode, as something a SwiftUI body can read.
///
/// `ProcessInfo.isLowPowerModeEnabled` is a plain synchronous read, so a view
/// that consults it directly is answered correctly exactly once and never told
/// when it changes — and `ActivityRing` is not re-evaluated on a clock, so it
/// could sit on the wrong answer for the whole length of a run. `@Observable`
/// makes the read a dependency: the one notification the system already sends
/// lands here, and only the views that actually asked are redrawn.
///
/// One observer for the process rather than one per ring, and the same
/// `static let shared` shape `Preferences` uses, for the same reason — the
/// property is main-actor isolated with the type, so its lazy initialiser runs
/// on the actor its `init` needs.
@MainActor
@Observable
final class PowerState {
    static let shared = PowerState()

    private(set) var isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    /// Held for the life of the process. Nothing ever removes it, because
    /// nothing ever releases the singleton it belongs to.
    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
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
    /// Every call site passes one; the default is the run-row size because
    /// that is where all but one of them are.
    var size: Size = .compact

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

/// A job's steps as one **fixed-width** bar, with the count spelled out beside it.
///
/// The strip this replaces was as long as the job had steps, which put the most
/// visible dimension in the row behind the least useful number: a ten-step job
/// and a sixteen-step job drew different lengths while being equally far along,
/// and the panel's width budget depended on what somebody put in their YAML. At
/// a constant width the coloured fraction means *progress*, two jobs are
/// comparable at a glance, and sixty steps cost exactly what six do.
///
/// The count beside it is the other half. A bar answers "roughly how far",
/// which is what the eye wants; `12/16` answers "exactly where", which is what
/// you need before deciding whether to go and look. Neither is worth counting
/// dots for.
struct StepBar: View {
    let job: Job
    /// Track width. Constant by design — see the note above.
    var width: CGFloat = 132
    var height: CGFloat = 5
    /// The pill's mini bar drops the fraction; the expanded panel keeps it.
    var showsCount: Bool = true
    /// Above this many steps the bar stops drawing one segment each and fills
    /// proportionally instead. A segment thinner than about two points is a
    /// smudge, and a job with sixty steps stopped being readable step-by-step
    /// long before sixty — the same argument that capped the dots this replaces.
    var segmentCap: Int = 24
    /// Whether the running segment breathes. Off in the pill, on in the panel:
    /// see `shouldPulse`.
    var pulses: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            track

            if showsCount {
                Text(label)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 42, alignment: .leading)
                    .help(countHelp)
            }
        }
        .onAppear { pulse = shouldPulse }
        .onChange(of: shouldPulse) { _, wanted in pulse = wanted }
    }

    // MARK: Track

    @ViewBuilder
    private var track: some View {
        Group {
            if job.steps.isEmpty {
                // A job whose steps have not arrived yet still deserves a bar:
                // the jobs endpoint returns steps only once the job starts, and
                // an empty slot reads as a rendering bug. Its own status is a
                // real answer — "failed" says more than the dash this replaces.
                Rectangle().fill(fill(for: job.status))
            } else if job.steps.count > segmentCap {
                proportional
            } else {
                segments
            }
        }
        .frame(width: width, height: height)
        .clipShape(Capsule(style: .continuous))
        .animation(Motion.content, value: settled)
    }

    /// One segment per step, sharing the width equally.
    private var segments: some View {
        HStack(spacing: 1) {
            ForEach(job.steps) { step in
                Rectangle()
                    .fill(fill(for: step.status))
                    .opacity(step.status == .inProgress && pulse ? 0.55 : 1)
                    .animation(pulseAnimation, value: pulse)
                    .frame(maxWidth: .infinity)
                    .help("\(job.name) › \(step.name): \(step.status.label)")
            }
        }
    }

    /// Too many steps to draw one each: a single fill, proportional to how many
    /// have settled.
    private var proportional: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Color.white.opacity(0.16)
                Rectangle()
                    .fill(StatusStyle.color(for: job.status).opacity(0.92))
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .help(countHelp)
    }

    // MARK: Numbers

    /// Steps that have reached a conclusion.
    ///
    /// Counted in place, for the reason `WorkflowRun.progress` gives one file
    /// over: `filter { … }.count` builds a whole array of `Step` and then keeps
    /// nothing but its length. Four readers ask for this on every body pass —
    /// the track's `.animation(value:)`, `fraction`, `label`, and `countHelp`,
    /// which is a `.help` argument and so is built whether or not anybody
    /// hovers — and a pill draws one of these per job per run, once a second,
    /// for as long as anything is building. That is an array allocation per
    /// job per reader per frame for a number that is one integer.
    private var settled: Int {
        var count = 0
        for step in job.steps where step.status != .inProgress && !isPending(step.status) {
            count += 1
        }
        return count
    }

    private var fraction: Double {
        guard !job.steps.isEmpty else { return 0 }
        return Double(settled) / Double(job.steps.count)
    }

    /// `12/16`, or the job's own conclusion when GitHub has sent no steps yet.
    private var label: String {
        job.steps.isEmpty ? job.status.label : "\(settled)/\(job.steps.count)"
    }

    private var countHelp: String {
        job.steps.isEmpty
            ? "\(job.name): \(job.status.label) — GitHub has sent no step detail"
            : "\(job.name): \(settled) of \(job.steps.count) steps finished"
    }

    // MARK: Paint

    private func fill(for status: RunStatus) -> Color {
        isPending(status)
            ? Color.white.opacity(0.16)
            : StatusStyle.color(for: status).opacity(0.92)
    }

    /// Not-yet-started work is a dim rail rather than a filled segment.
    private func isPending(_ status: RunStatus) -> Bool {
        status == .queued || status == .pending || status == .requested
    }

    // MARK: Motion

    /// Only the running segment breathes, and only where it is cheap.
    ///
    /// The dots this replaces pulsed per step. One step runs at a time inside a
    /// job, so this is the same cost rather than more — and it stays off the
    /// pill, where the island has already decided that per-step animation
    /// behind a glanceable badge was the wrong trade.
    private var shouldPulse: Bool {
        pulses && !reduceMotion && job.steps.contains(where: { $0.status == .inProgress })
    }

    private var pulseAnimation: Animation? {
        guard shouldPulse else { return nil }
        return .easeInOut(duration: 0.65).repeatForever(autoreverses: true)
    }
}

/// The run's jobs as a row of mini bars — one bar per job, in reading order.
///
/// GitHub's nesting is a run holding **jobs**, each holding **steps**, so a bar
/// is a job and its segments are that job's steps.
///
/// One bar per job rather than one segment per step laid end to end. The old
/// strip grew with the run's total step count, so a workflow that gained a
/// linting step pushed the elapsed time further along a 32pt row with no width
/// to spare; worse, its length said "this run has many steps" when the only
/// question the pill is ever asked is "how far along is it". A bar is 34pt
/// whatever it holds, so the width budget follows the job count — which is
/// stable — and what is left over pays for the name of the step actually
/// running.
struct JobTrack: View {
    let run: WorkflowRun
    /// Compact drops the trailing job name, for the collapsed pill.
    var compact: Bool = false

    /// How many bars the pill draws before it starts counting instead.
    ///
    /// A bounded budget is the entire claim this type makes, and a matrix build
    /// is what tests it: twelve jobs of four steps each drew a narrow strip
    /// under the old step-driven layout and would draw 34pt apiece under this
    /// one, which is 400pt of a 520pt row. Five bars plus an overflow count is
    /// 190pt, and past five the individual bars had stopped being separable
    /// anyway — what is left to say is *how many*, and a number says it.
    private var barLimit: Int { compact ? 5 : 8 }

    private var shown: [Job] { Array(run.jobList.prefix(barLimit)) }
    private var hidden: Int { max(run.jobList.count - barLimit, 0) }

    var body: some View {
        HStack(spacing: compact ? 5 : 7) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, job in
                StepBar(
                    job: job,
                    width: compact ? 34 : 44,
                    height: compact ? 4 : 5,
                    showsCount: false,
                    segmentCap: compact ? 12 : 16,
                    // The pill is the one place the island has decided not to
                    // animate per step. See `StepBar.shouldPulse`.
                    pulses: false
                )
                .help("\(job.name): \(job.status.label)")
                .transition(.scale(scale: 0.4, anchor: .leading).combined(with: .opacity))
            }

            if hidden > 0 {
                Text("+\(hidden)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.38))
                    .monospacedDigit()
                    .help("\(hidden) more job\(hidden == 1 ? "" : "s") — hover to see them all")
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
