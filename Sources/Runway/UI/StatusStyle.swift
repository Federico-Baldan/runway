import SwiftUI

/// Colour + glyph vocabulary shared by the pill and the expanded rows.
enum StatusStyle {
    static func color(for status: RunStatus) -> Color {
        if status.isActive { return .blue }
        if status.isFailure { return .red }
        switch status {
        case .success: return .green
        case .cancelled, .skipped, .neutral, .stale: return .secondary
        case .actionRequired: return .orange
        default: return .secondary
        }
    }

    /// SF Symbol for a run / job / step status.
    static func symbol(for status: RunStatus) -> String {
        if status.isActive { return "circle.dotted" }
        switch status {
        case .success: return "checkmark.circle.fill"
        case .failure, .startupFailure: return "xmark.circle.fill"
        case .timedOut: return "clock.badge.xmark"
        case .cancelled: return "slash.circle"
        case .skipped: return "arrow.right.circle"
        case .neutral, .stale: return "minus.circle"
        case .actionRequired: return "hand.raised.circle"
        default: return "circle"
        }
    }

    static func color(for mood: IslandMood) -> Color {
        switch mood {
        case .running: return .blue
        case .failed: return .red
        case .success: return .green
        case .error: return .orange
        case .idle: return .secondary
        }
    }

    /// A glyph for the event that started a run — push, PR, schedule, manual.
    static func eventSymbol(for event: String?) -> String? {
        switch event {
        case "push": return "arrow.up.circle"
        case "pull_request", "pull_request_target": return "arrow.triangle.pull"
        case "schedule": return "clock"
        case "workflow_dispatch": return "hand.tap"
        case "release": return "shippingbox"
        case "repository_dispatch", "workflow_call": return "arrow.triangle.branch"
        default: return nil
        }
    }
}

/// A spinner that only animates while a run is genuinely active.
///
/// `repeatForever` never settles, so for as long as this is on screen it holds
/// the display link open at the panel's refresh rate. That is the right trade
/// while something is genuinely building — but not for someone who has asked
/// the system to stop animating things, so Reduce Motion drops it to a static
/// glyph and takes the redraw cost to zero.
struct ActivityGlyph: View {
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    private var spin: Animation? {
        guard !reduceMotion else { return nil }
        return Animation.linear(duration: 2).repeatForever(autoreverses: false)
    }

    var body: some View {
        Image(systemName: "circle.dotted")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(color)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(spin, value: spinning)
            .onAppear { spinning = !reduceMotion }
    }
}

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
                Image(systemName: run.isRerun ? "arrow.clockwise.circle.fill" : "person.circle.fill")
                    .font(.system(size: compact ? 8 : 9))
                    .foregroundStyle(.white.opacity(0.45))
                Text(login)
                    .font(.system(size: compact ? 9 : 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
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

/// The run's jobs as a strip of dots.
///
/// GitLab drew stages, each holding jobs. GitHub's equivalent nesting is one
/// level down — a run holds **jobs**, each holding **steps** — so a job takes
/// the place of a stage here and a step takes the place of a job. The visual
/// grammar is unchanged; only what the dots count has moved.
struct JobStrip: View {
    let run: WorkflowRun
    /// Compact mode drops the labels and draws dots only, for the collapsed pill.
    var compact: Bool = false

    var body: some View {
        HStack(spacing: compact ? 4 : 6) {
            ForEach(Array(run.jobList.enumerated()), id: \.offset) { index, job in
                if index > 0 {
                    Capsule()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: compact ? 4 : 6, height: 1)
                }

                HStack(spacing: 3) {
                    // A job whose steps have not arrived yet still deserves a
                    // dot: the jobs endpoint returns steps only once the job
                    // starts, and an empty row reads as a rendering bug.
                    if job.steps.isEmpty {
                        StepDot(status: job.status, name: job.name, job: job.name)
                            .transition(.scale(scale: 0.3).combined(with: .opacity))
                    } else {
                        ForEach(job.steps) { step in
                            StepDot(status: step.status, name: step.name, job: job.name)
                                .transition(.scale(scale: 0.3).combined(with: .opacity))
                        }
                    }
                }
            }

            if !compact, let running = runningLabel {
                Text(running)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 2)
            }
        }
        .frame(height: compact ? 10 : 12)
    }

    private var runningLabel: String? {
        let names = run.runningJobs.map(\.name)
        guard !names.isEmpty else { return nil }
        return names.joined(separator: ", ")
    }
}

/// One step, drawn as a filled dot.
struct StepDot: View {
    let status: RunStatus
    let name: String
    let job: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var isRunning: Bool { status == .inProgress }
    /// Not-yet-started work reads as an outline rather than a solid dot.
    private var isPending: Bool {
        status == .queued || status == .pending || status == .waiting
            || status == .requested || status == .actionRequired
    }

    private var pulseAnimation: Animation {
        guard isRunning, !reduceMotion else { return .default }
        return Animation.easeInOut(duration: 0.65).repeatForever(autoreverses: true)
    }

    var body: some View {
        Circle()
            .strokeBorder(
                StatusStyle.color(for: status).opacity(isPending ? 0.65 : 0),
                lineWidth: 1.5
            )
            .background(
                Circle().fill(isPending ? Color.clear : StatusStyle.color(for: status))
            )
            .frame(width: 7, height: 7)
            .scaleEffect(isRunning && pulse ? 1.35 : 1.0)
            .opacity(isRunning && pulse ? 0.55 : 1.0)
            .animation(pulseAnimation, value: pulse)
            .onAppear { pulse = isRunning && !reduceMotion }
            .onChange(of: isRunning) { _, running in pulse = running && !reduceMotion }
            .help("\(job) › \(name): \(status.label)")
    }
}
