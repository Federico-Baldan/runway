import Observation
import SwiftUI

/// Where the resting mark sits inside the band under the cutout.
///
/// The band is the cutout's width, which is a lot of room for one small mark,
/// and where it sits changes what it reads as: centred it is a status light,
/// tucked to one side it is something perched on the edge of the notch looking
/// out. There is no right answer, so it is a preference.
public enum IdleMarkPosition: String, Sendable, CaseIterable {
    case leading
    case center
    case trailing

    var alignment: Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    /// Which way the eye favours when it looks around from here.
    ///
    /// A mark perched at the left edge that keeps glancing further left is
    /// looking off the end of its own world. Bias it back towards the middle.
    var gazeBias: CGFloat {
        switch self {
        case .leading: return 0.35
        case .center: return 0
        case .trailing: return -0.35
        }
    }

    public var title: String {
        switch self {
        case .leading: return "Left"
        case .center: return "Centre"
        case .trailing: return "Right"
        }
    }
}

/// The blinking, glancing part of the idle mark.
///
/// A separate `@MainActor` object rather than `@State` inside the view, for the
/// same reason `IslandModel` owns its ticker: the loop has to be *stoppable*,
/// by name, from outside — when the screen sleeps, when a run arrives, when the
/// view goes away — and a task hanging off a struct that SwiftUI is free to
/// recreate on any pass is not something you can hold on to. It also keeps the
/// one place that spends wakeups in one place.
///
/// ## Why the movement is not springy
///
/// The first version moved the eye with `.spring`, and a springy eye is the one
/// thing that reads as unmistakably fake. Real gaze shifts are **saccades**:
/// abrupt, ballistic, 40-70ms end to end, with no ease-in and no overshoot —
/// the eye is either fixating or in flight, never gliding. Everything soft in
/// here is on the *lid*, which is muscle and does ease.
///
/// The rest is what makes a sequence of saccades read as looking around rather
/// than twitching: a fixation between each one long enough to be a look
/// (220-900ms), two to four of them per outing, a bias back towards centre so
/// it never keeps staring off the same edge, and a blink on the way home —
/// gaze returns carry one almost every time, which is why omitting it is what
/// made the old single glance look like a glitch rather than a glance.
@MainActor
@Observable
final class IdleMarkAnimator {
    /// How shut the lid is, 0 open to 1 closed. A capsule squashed to a
    /// fraction of its height is a closed lid, and nothing else has to move for
    /// a blink to read.
    private(set) var lid: CGFloat = 0
    /// Where the eye is looking. Both axes -1...1; the view scales them down to
    /// the couple of points the mark actually has to move in.
    private(set) var gaze: CGSize = .zero

    @ObservationIgnored private var beatTask: Task<Void, Never>?
    /// Set while the pointer is on the island — the eye is looking back, so it
    /// must not wander off mid-conversation.
    @ObservationIgnored var isAttentive = false
    /// Which way this mark leans when it looks around. See `IdleMarkPosition`.
    @ObservationIgnored var bias: CGFloat = 0

    /// Where the lid rests between blinks. Not always fully open: an eye
    /// looking down carries a lowered lid, which is most of what makes a
    /// downward look read as downward on a mark this small.
    @ObservationIgnored private var restLid: CGFloat = 0

    /// `nonisolated` so the view can hold one in `@State`: a stored-property
    /// default is evaluated in a synchronous, non-isolated context, and a
    /// main-actor initialiser cannot be called from one. Nothing here touches
    /// isolated state — every stored property has a `Sendable` default.
    nonisolated init() {}

    /// Begin the loop, unless one is already going or motion is not wanted.
    func start(reduceMotion: Bool) {
        guard beatTask == nil else { return }
        guard !reduceMotion else {
            // Reduce Motion still gets an eye. It gets an open one.
            lid = 0
            restLid = 0
            gaze = .zero
            return
        }

        beatTask = Task { [weak self] in
            // The first beat comes soon, the rest come slowly. Arriving is the
            // moment the mark has to say it is alive — a run has just cleared
            // and somebody is quite likely still looking at the notch — and
            // twelve seconds of a perfectly still eye reads as a stuck window.
            var first = true

            while !Task.isCancelled {
                // Randomised rather than fixed: a blink exactly every six
                // seconds is a metronome, and a metronome in the corner of your
                // eye is a thing you end up watching.
                //
                // Half a second of tolerance — the same trick the poll loop and
                // the elapsed ticker use — lets macOS coalesce this wakeup with
                // others already scheduled nearby instead of bringing the CPU
                // out of idle for a blink.
                let pause = first ? Double.random(in: 1.2...3) : Double.random(in: 4...12)
                first = false
                do {
                    try await Task.sleep(for: .seconds(pause), tolerance: .milliseconds(500))
                } catch {
                    return // cancelled
                }
                guard let self, !Task.isCancelled else { return }
                await self.play(self.nextBeat())
            }
        }
    }

    /// Stop and reset. Called when the screen sleeps and when the view leaves.
    func stop() {
        beatTask?.cancel()
        beatTask = nil
        lid = 0
        restLid = 0
        gaze = .zero
    }

    /// Somebody arrived, or left. Looking back is the whole point of having an
    /// eye, so this is not just a flag: the gaze comes home for it.
    func attend(_ attentive: Bool) {
        isAttentive = attentive
        guard attentive else { return }
        restLid = 0
        withAnimation(.easeOut(duration: 0.11)) {
            gaze = .zero
            lid = 0
        }
    }

    // MARK: - Beats

    /// One of the small things an idle mark does while you are not watching it.
    private enum Beat {
        case blink
        case doubleBlink
        /// A look around: this many fixations before it comes back.
        case lookAround(Int)
    }

    /// Mostly blinks, sometimes a look around. Weighted by hand: a mark that
    /// looked around as often as it blinked would read as nervous rather than
    /// alive, and one that never did reads as a status LED.
    private func nextBeat() -> Beat {
        switch Int.random(in: 0..<20) {
        case 0...9: return .blink
        case 10...12: return .doubleBlink
        case 13...17: return .lookAround(2)
        default: return .lookAround(Int.random(in: 3...4))
        }
    }

    private func play(_ beat: Beat) async {
        switch beat {
        case .blink:
            await blink()
        case .doubleBlink:
            await blink()
            try? await Task.sleep(for: .milliseconds(130))
            await blink()
        case .lookAround(let fixations):
            await lookAround(fixations)
        }
    }

    /// Two to four saccades away from centre, then home, then a blink.
    private func lookAround(_ fixations: Int) async {
        // Never mid-hover: the eye is supposed to be looking at whoever just
        // arrived, and wandering off then reads as avoiding them.
        guard !isAttentive else { return }

        var previous: CGSize = .zero
        for _ in 0..<fixations {
            let target = nextTarget(after: previous)
            previous = target
            saccade(to: target)
            do {
                try await Task.sleep(for: .milliseconds(Int.random(in: 220...900)))
            } catch {
                return
            }
            // Hovering mid-look wins: come home and stop.
            guard !isAttentive, !Task.isCancelled else { break }
        }

        saccade(to: .zero)
        try? await Task.sleep(for: .milliseconds(70))
        // A gaze return almost always carries a blink. Leaving it out is what
        // made the old version's single glance read as a glitch.
        await blink()
    }

    /// The next place to look: sideways more than up and down, never twice to
    /// the same side, pulled back towards the middle by the mark's position.
    private func nextTarget(after previous: CGSize) -> CGSize {
        // Horizontal travel dominates. The mark is 1.4 times as wide as it is
        // tall and the eye has barely a point of room above and below, so a
        // mostly-vertical look has nowhere to go and reads as a wobble.
        var x = CGFloat.random(in: 0.45...1) * (previous.width > 0 ? -1 : 1)
        if previous == .zero, Bool.random() { x = -x }
        x = max(min(x + bias, 1), -1)

        // Down more often than up: an eye that keeps looking at the ceiling is
        // doing something, and an idle mark is not doing anything.
        let y: CGFloat = switch Int.random(in: 0..<10) {
        case 0...4: 0
        case 5...7: CGFloat.random(in: 0.35...0.8)
        default: -CGFloat.random(in: 0.3...0.7)
        }

        return CGSize(width: x, height: y)
    }

    /// One ballistic jump. `easeOut` with no bounce, over the 45-70ms a real
    /// saccade takes — the eye arrives, it does not settle.
    private func saccade(to target: CGSize) {
        // The lid rides down with a downward look and comes back up with the
        // gaze. It is the same muscle; animating it separately looks like two
        // parts of one thing moving independently, which is exactly what it is
        // not supposed to look like.
        restLid = target.height > 0.3 ? 0.22 : 0
        withAnimation(.easeOut(duration: Double.random(in: 0.045...0.07))) {
            gaze = target
            lid = restLid
        }
    }

    /// Asymmetric on purpose: lids snap shut and drift open, and a blink with
    /// matching in and out timings is the other thing that reads as mechanical.
    private func blink() async {
        withAnimation(.easeIn(duration: 0.06)) { lid = 1 }
        try? await Task.sleep(for: .milliseconds(75))
        withAnimation(.easeOut(duration: 0.11)) { lid = restLid }
    }
}

/// The brand mark, alive, for an island with nothing to report.
///
/// ## Why the island stays on screen for this
///
/// Everything else about Runway is built on the island arriving when a workflow
/// starts and leaving when it ends, and this is the one exception: with
/// `Preferences.idleMark` on, a notched Mac keeps a few points of island under
/// the cutout with the mark sitting in it. It earns that because of *where* it
/// is. The island's black is the same black as the camera housing, and
/// `IslandShape` fillets the join between them, so at rest the mark reads as
/// something living inside the notch rather than a window somebody left open —
/// and it answers the one question an app that hides when idle cannot: is this
/// thing even running?
///
/// Notch-only for the same reason. On a display without a cutout the island is
/// a floating pill under the menu bar, and a floating pill that never leaves is
/// furniture. `NotchPanelController` enforces that; it is the only part of the
/// app that knows whether this screen has a notch.
///
/// ## The energy budget
///
/// This app has gone to some trouble not to schedule wakeups nobody asked for:
/// no `repeatForever` animation outside the one state that is asking for
/// something back, no ticking while the screen is dark. A mascot that blinks is
/// exactly the sort of thing that quietly undoes all of it, so this one holds no
/// display link. It sleeps four to twelve seconds, plays one short beat, and
/// sleeps again — and none at all when the screen is asleep, when Reduce Motion
/// is on, or when anything is running, because then the island is drawing a
/// status badge and this view is not on screen at all.
///
/// A blink is two wakeups and a look around is at most ten over two seconds, so
/// the busiest minute this can have is roughly thirty — still single figures on
/// average, still each with half a second of tolerance for macOS to coalesce.
struct IdleMark: View {
    /// Height of the mark in points. The width follows from `BrandGeometry`.
    var height: CGFloat = 12
    /// True while the display is asleep. Stops the loop rather than slowing it.
    var isSuspended: Bool = false
    /// True while somebody is looking at the island: the eye looks back, opens
    /// a little wider, and stops wandering off.
    var isAttentive: Bool = false
    /// Where the mark sits in its band, which is also which way it looks.
    var position: IdleMarkPosition = .center

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animator = IdleMarkAnimator()

    private var width: CGFloat { (height * BrandGeometry.aspect).rounded() }
    private var eye: CGFloat { (height * BrandGeometry.eyeRatio).rounded() }

    var body: some View {
        ZStack {
            // The mark itself: a notch, barely lighter than the black it sits
            // on. Meant to be found rather than noticed — under a real cutout
            // the black around it is hardware, and anything with contrast up
            // there reads as a rendering fault.
            UnevenRoundedRectangle(
                topLeadingRadius: width * BrandGeometry.topCornerRatio,
                bottomLeadingRadius: height / 2,
                bottomTrailingRadius: height / 2,
                topTrailingRadius: width * BrandGeometry.topCornerRatio,
                style: .continuous
            )
            .fill(Color.white.opacity(0.13))

            // Filled, where the menu bar cut of the mark knocks the same circle
            // out. A hole is what survives being a template image; a pupil is
            // what makes something look back at you, and this one is never a
            // template.
            Capsule(style: .continuous)
                .fill(Color.white.opacity(isAttentive ? 0.95 : 0.78))
                .frame(width: eye, height: max(eye * (1 - animator.lid * 0.86), 1))
                .offset(
                    x: animator.gaze.width * eye * 0.55,
                    y: animator.gaze.height * eye * 0.30
                )
                .scaleEffect(isAttentive ? 1.12 : 1)
                .shadow(color: .white.opacity(0.30), radius: height * 0.14)
                .animation(.spring(duration: 0.30, bounce: 0.24), value: isAttentive)
        }
        .frame(width: width, height: height)
        .onAppear {
            animator.bias = position.gazeBias
            animator.isAttentive = isAttentive
            if !isSuspended { animator.start(reduceMotion: reduceMotion) }
        }
        .onDisappear { animator.stop() }
        .onChange(of: isSuspended) { _, suspended in
            // The screen going dark is the one case worth stopping for: nobody
            // can see a blink through a closed lid, and a failed run can keep
            // the island on screen for ten minutes behind one.
            if suspended {
                animator.stop()
            } else {
                animator.start(reduceMotion: reduceMotion)
            }
        }
        .onChange(of: isAttentive) { _, attentive in animator.attend(attentive) }
        .onChange(of: position) { _, new in animator.bias = new.gazeBias }
        .accessibilityLabel(Text("Runway — nothing running"))
        .help("Nothing is running. Hover for the last update.")
    }
}
