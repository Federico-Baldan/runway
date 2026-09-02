import Observation
import SwiftUI

/// The blinking, glancing part of the idle mark.
///
/// A separate `@MainActor` object rather than `@State` inside the view, for the
/// same reason `IslandModel` owns its ticker: the loop has to be *stoppable*,
/// by name, from outside — when the screen sleeps, when a run arrives, when the
/// view goes away — and a task hanging off a struct that SwiftUI is free to
/// recreate on any pass is not something you can hold on to. It also keeps the
/// one place that spends wakeups in one place.
@MainActor
@Observable
final class IdleMarkAnimator {
    /// The eye, mid-blink: a capsule squashed to a fraction of its height is a
    /// closed lid, and nothing else has to move for a blink to read.
    private(set) var lidClosed = false
    /// Where the eye is looking, -1 (left) to 1 (right).
    private(set) var glance: CGFloat = 0

    @ObservationIgnored private var beatTask: Task<Void, Never>?
    /// Set while the pointer is on the island — the eye is looking back, so it
    /// must not wander off mid-conversation.
    @ObservationIgnored var isAttentive = false

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
            lidClosed = false
            glance = 0
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
        lidClosed = false
        glance = 0
    }

    // MARK: - Beats

    /// One of the small things an idle mark does while you are not watching it.
    private enum Beat {
        case blink
        case doubleBlink
        case glance(CGFloat)
    }

    /// Mostly blinks, occasionally a look around. Weighted by hand: a mark that
    /// glanced as often as it blinked would read as nervous rather than alive.
    private func nextBeat() -> Beat {
        switch Int.random(in: 0..<10) {
        case 0...4: return .blink
        case 5, 6: return .doubleBlink
        case 7, 8: return .glance(-1)
        default: return .glance(1)
        }
    }

    private func play(_ beat: Beat) async {
        switch beat {
        case .blink:
            await blink()
        case .doubleBlink:
            await blink()
            try? await Task.sleep(for: .milliseconds(140))
            await blink()
        case .glance(let direction):
            // Never mid-hover: the eye is supposed to be looking at whoever
            // just arrived, and wandering off then reads as avoiding them.
            guard !isAttentive else { return }
            withAnimation(.spring(duration: 0.34, bounce: 0.30)) { glance = direction }
            try? await Task.sleep(for: .milliseconds(Int.random(in: 650...1_500)))
            withAnimation(.spring(duration: 0.44, bounce: 0.16)) { glance = 0 }
        }
    }

    private func blink() async {
        withAnimation(.easeIn(duration: 0.07)) { lidClosed = true }
        try? await Task.sleep(for: .milliseconds(90))
        withAnimation(.easeOut(duration: 0.12)) { lidClosed = false }
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
/// is. The island's black is the same black as the camera housing, so at rest
/// the mark reads as something living inside the notch rather than a window
/// somebody left open — and it answers the one question an app that hides when
/// idle cannot: is this thing even running?
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
/// display link. It sleeps four to twelve seconds, plays one short animation,
/// and sleeps again — single figures of wakeups a minute, each with half a
/// second of tolerance — and none at all when the screen is asleep, when Reduce
/// Motion is on, or when anything is running, because then the island is drawing
/// a status badge and this view is not on screen at all.
struct IdleMark: View {
    /// Height of the mark in points. The width follows from `BrandGeometry`.
    var height: CGFloat = 10
    /// True while the display is asleep. Stops the loop rather than slowing it.
    var isSuspended: Bool = false
    /// True while somebody is looking at the island: the eye looks back, opens
    /// a little wider, and stops wandering off.
    var isAttentive: Bool = false

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
                .frame(width: eye, height: eye * (animator.lidClosed ? 0.14 : 1))
                .offset(x: animator.glance * eye * 0.55)
                .scaleEffect(isAttentive ? 1.12 : 1)
                .shadow(color: .white.opacity(0.30), radius: height * 0.14)
                .animation(.spring(duration: 0.30, bounce: 0.24), value: isAttentive)
        }
        .frame(width: width, height: height)
        .onAppear {
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
        .onChange(of: isAttentive) { _, attentive in animator.isAttentive = attentive }
        .accessibilityLabel(Text("Runway — nothing running"))
        .help("Nothing is running. Hover for the last update.")
    }
}
