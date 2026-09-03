import Foundation
import IOKit.ps
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
/// The two exceptions earn it. `follow` is smooth pursuit, which is the one
/// kind of real eye movement that eases, and it only happens when there is
/// something to track; `drift` is what an eye does with nothing to fix on at
/// all. Everything else jumps.
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
    /// The lid and the gaze, as one animatable value.
    struct Eye: Equatable, Sendable {
        /// How shut the lid is, 0 open to 1 closed. A capsule squashed to a
        /// fraction of its height is a closed lid, and nothing else has to
        /// move for a blink to read.
        var lid: CGFloat = 0
        /// Where the eye is looking. Both axes -1...1; the view scales them
        /// into the points the mark actually has room for.
        var gaze: CGSize = .zero
        /// How wide the pupil is, as a multiple of its resting size.
        ///
        /// The amount of pupil showing is most of what separates a squint from
        /// a stare on a mark with one moving part, and it costs the view one
        /// multiplication in a `.frame` that was already there.
        var dilation: CGFloat = 1
    }

    private(set) var eye = Eye()

    /// The animation the *next* change to `eye` should use, published beside
    /// it so the view can scope one to the other.
    ///
    /// This used to be `withAnimation` around each mutation, which hands the
    /// animation to the ambient transaction — and this view sits several
    /// `.animation(_:value:)` scopes deep inside `IslandView`, every one of
    /// them a chance for a 60ms blink to be re-timed by whatever the island is
    /// animating, or dropped. An animation named on the eye itself belongs to
    /// the eye and cannot be overruled from above.
    private(set) var motion: Animation = .easeOut(duration: 0.11)

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

    /// True once the mark has given up and closed its eye. See `doze`.
    @ObservationIgnored private var isAsleep = false
    /// Set when `attend` finds a sleeping mark: the restarted loop owes a wake.
    @ObservationIgnored private var pendingWake = false
    /// When the current waking spell began, for deciding when to sleep.
    @ObservationIgnored private var awakeSince = ContinuousClock.now
    /// When it dozed off, for deciding whether waking has earned a yawn.
    @ObservationIgnored private var asleepSince: ContinuousClock.Instant?
    /// The last Reduce Motion answer, so the loop can be restarted from inside
    /// without the view having to be asked again.
    @ObservationIgnored private var reduceMotionWanted = false

    /// Move the eye, saying how. The only writer of either property.
    private func move(_ next: Eye, _ animation: Animation) {
        motion = animation
        eye = next
    }

    /// Keep a gaze axis inside its range once the mark's own lean is added.
    private func leaning(_ x: CGFloat, by amount: CGFloat) -> CGFloat {
        max(min(x + amount, 1), -1)
    }

    /// `nonisolated` so the view can hold one in `@State`: a stored-property
    /// default is evaluated in a synchronous, non-isolated context, and a
    /// main-actor initialiser cannot be called from one. Nothing here touches
    /// isolated state — every stored property has a `Sendable` default.
    nonisolated init() {}

    /// Begin the loop, unless one is already going or motion is not wanted.
    func start(reduceMotion: Bool) {
        reduceMotionWanted = reduceMotion
        guard beatTask == nil else { return }
        guard !reduceMotion else {
            // Reduce Motion still gets an eye. It gets an open one.
            restLid = 0
            isAsleep = false
            pendingWake = false
            move(Eye(), .easeOut(duration: 0.11))
            return
        }

        awakeSince = ContinuousClock.now

        // The first beat comes soon, the rest come slowly. Arriving is the
        // moment the mark has to say it is alive — a run has just cleared and
        // somebody is quite likely still looking at the notch — and twelve
        // seconds of a perfectly still eye reads as a stuck window. A wake owed
        // from `attend` is more urgent still: somebody is hovering it *now*.
        let firstPause = pendingWake ? 0.02 : Double.random(in: 1.2...3)

        beatTask = Task { [weak self] in
            // The pause for the next turn is worked out at the end of this one,
            // so nothing has to be read off `self` before the sleep and the
            // loop holds no reference to the animator while it waits.
            var pause = firstPause
            var tolerance = Duration.milliseconds(500)

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(pause), tolerance: tolerance)
                } catch {
                    return // cancelled
                }
                guard let self, !Task.isCancelled else { return }

                await self.tick()

                let next = self.nextPause()
                pause = next.seconds
                tolerance = next.tolerance
            }
        }
    }

    /// Stop and reset. Called when the screen sleeps and when the view leaves.
    func stop() {
        beatTask?.cancel()
        beatTask = nil
        restLid = 0
        isAsleep = false
        pendingWake = false
        asleepSince = nil
        move(Eye(), .easeOut(duration: 0.11))
    }

    /// Somebody arrived, or left. Looking back is the whole point of having an
    /// eye, so this is not just a flag: the gaze comes home for it.
    func attend(_ attentive: Bool) {
        isAttentive = attentive
        awakeSince = ContinuousClock.now
        guard attentive else { return }

        // Hovering a sleeping mark wakes it. The loop is restarted rather than
        // signalled, because asleep it is sitting inside a sleep that can be a
        // minute and a half long, and nobody is going to wait that out to be
        // looked back at.
        if isAsleep {
            isAsleep = false
            pendingWake = true
            beatTask?.cancel()
            beatTask = nil
            start(reduceMotion: reduceMotionWanted)
            return
        }

        restLid = 0
        move(Eye(), .easeOut(duration: 0.11))
    }

    // MARK: - The loop

    /// One turn: wake if one is owed, stir if asleep, doze if it is time, and
    /// otherwise play a beat.
    private func tick() async {
        if pendingWake {
            pendingWake = false
            await wake()
            return
        }
        if isAsleep {
            await stir()
            return
        }
        if !isAttentive,
           awakeSince.duration(to: ContinuousClock.now) >= PowerSource.current.sleepDelay {
            doze()
            return
        }
        await play(nextBeat())
    }

    /// How long to wait before the next turn, and how much slack macOS may take
    /// in scheduling it.
    ///
    /// Randomised rather than fixed: a blink exactly every six seconds is a
    /// metronome, and a metronome in the corner of your eye is a thing you end
    /// up watching. The tolerance — the same trick the poll loop and the
    /// elapsed ticker use — lets macOS coalesce this wakeup with others already
    /// scheduled nearby instead of bringing the CPU out of idle for a blink.
    private func nextPause() -> (seconds: Double, tolerance: Duration) {
        guard !isAsleep else {
            // Asleep, the mark is not trying to be watched, so the slack is
            // seconds rather than milliseconds.
            return (Double.random(in: PowerSource.current.stirGap), .seconds(5))
        }
        return (Double.random(in: 4...12), .milliseconds(500))
    }

    // MARK: - Beats

    /// One of the small things an idle mark does while you are not watching it.
    enum Beat {
        case blink
        case doubleBlink
        /// A long, unhurried close, twice a real blink's length.
        case slowBlink
        /// The lid comes halfway down and stays there for a moment.
        case squint
        /// Three fast partial blinks.
        case flutter
        /// The lid sinks under its own weight, then catches itself.
        case drowse
        /// A look around: this many fixations before it comes back.
        case lookAround(Int)
        /// A glance away and straight back, then the same glance again — held.
        case doubleTake
        /// Smooth pursuit: something crosses the notch and the eye tracks it.
        case follow
        /// One slow circuit of the eye's whole range.
        case roll
        /// Two quick dips. Addressed to whoever is there.
        case nod
        /// Left, right, left. The counterpart to the nod.
        case shake
        /// The pupil contracts hard and locks dead centre.
        case focus
        /// The gaze wanders off with nothing to fix on and slowly comes back.
        case drift
        /// The lid drops first and the look happens from under it.
        case peek
        /// Short even saccades marching across, the way an eye crosses a line.
        case scan

        /// What this beat costs, for deciding whether it is affordable.
        ///
        /// Wakeups are only half the bill. A wakeup is a timer firing; an
        /// *animated second* is the compositor kept busy for that long, and on
        /// a battery the second one is what shows up. Both are counted from the
        /// timings written into the methods below, so they cannot drift far.
        var cost: (moves: Int, seconds: Double) {
            switch self {
            case .blink: return (2, 0.17)
            case .doubleBlink: return (4, 0.47)
            case .slowBlink: return (2, 0.45)
            case .squint: return (2, 0.29)
            case .flutter: return (6, 0.36)
            case .drowse: return (4, 1.16)
            case .lookAround(let fixations):
                return (fixations + 3, Double(fixations) * 0.13 + 0.23)
            case .doubleTake: return (6, 0.40)
            case .follow: return (4, 1.44)
            case .roll: return (10, 1.51)
            case .nod: return (5, 0.24)
            case .shake: return (5, 0.40)
            case .focus: return (4, 0.48)
            case .drift: return (4, 2.07)
            case .peek: return (5, 0.43)
            case .scan: return (8, 0.53)
            }
        }

        /// Cheap enough to keep once the lid is shut and the Mac is on its own
        /// battery: half a second of animation or less, and no more than six
        /// moves. A rule rather than a hand-picked list, so a beat added later
        /// classifies itself.
        var isFrugal: Bool { cost.seconds <= 0.5 && cost.moves <= 6 }

        /// Moves the lid and leaves the gaze alone. The gaze is what costs —
        /// every fixation is a wakeup — so these are what is left in Low Power
        /// Mode, and they happen to be the cheapest things here anyway.
        var isLidOnly: Bool {
            switch self {
            case .blink, .doubleBlink, .slowBlink, .squint, .flutter: return true
            default: return false
            }
        }
    }

    /// What the Mac is running on, which decides how much the mark may spend.
    ///
    /// Checked per beat rather than cached: it is one call every four to twelve
    /// seconds, and reading it once at launch would mean a Mac unplugged at
    /// lunchtime kept spending like it was still on the wall.
    enum PowerSource {
        case wallPower
        case battery
        case lowPower

        static var current: PowerSource {
            // The setting the user actually chose outranks what they are
            // plugged into: Low Power Mode on the wall still means "spend less".
            if ProcessInfo.processInfo.isLowPowerModeEnabled { return .lowPower }

            let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
            guard let kind = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue()
            else { return .wallPower }

            // Anything that is not the battery — wall power, and desktops,
            // which report `kIOPSACPowerValue` with no battery at all.
            return (kind as String) == kIOPSBatteryPowerValue ? .battery : .wallPower
        }

        /// How long the mark goes without anybody caring before it sleeps.
        var sleepDelay: Duration {
            switch self {
            case .wallPower: return .seconds(180)
            case .battery: return .seconds(75)
            case .lowPower: return .seconds(20)
            }
        }

        /// How long between stirs while asleep.
        var stirGap: ClosedRange<Double> {
            switch self {
            case .wallPower: return 40...90
            case .battery: return 60...120
            case .lowPower: return 90...150
            }
        }

        func allows(_ beat: Beat) -> Bool {
            switch self {
            case .wallPower: return true
            case .battery: return beat.isFrugal
            case .lowPower: return beat.isLidOnly
            }
        }
    }

    /// Every beat with its share of the draw, filtered to what the Mac can
    /// currently afford.
    ///
    /// Weighted by hand: blinks have to dominate, because a mark that looked
    /// around as often as it blinked would read as nervous rather than alive,
    /// and one that never did reads as a status LED. The weights are summed
    /// from the table rather than assumed to total anything, so dropping beats
    /// on battery reweights the rest instead of leaving a dead zone in the draw.
    ///
    /// Rebuilt per draw rather than stored: seventeen tuples every few seconds
    /// is free, and it is what keeps the random inside `lookAround` fresh.
    private var pool: [(weight: Int, beat: Beat)] {
        let all: [(weight: Int, beat: Beat)] = [
            (20, .blink),
            (7, .doubleBlink),
            (10, .lookAround(2)),
            (4, .lookAround(Int.random(in: 3...4))),
            (6, .slowBlink),
            (5, .squint),
            (3, .flutter),
            (4, .drowse),
            (6, .doubleTake),
            (6, .follow),
            (3, .roll),
            (4, .nod),
            (3, .shake),
            (5, .focus),
            (5, .drift),
            (5, .peek),
            (4, .scan)
        ]
        let power = PowerSource.current
        return all.filter { power.allows($0.beat) }
    }

    private func nextBeat() -> Beat {
        let entries = pool
        let total = entries.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return .blink }

        var draw = Int.random(in: 0..<total)
        for entry in entries {
            draw -= entry.weight
            if draw < 0 { return entry.beat }
        }
        return .blink
    }

    private func play(_ beat: Beat) async {
        switch beat {
        case .blink:
            await blink()
        case .doubleBlink:
            await blink()
            try? await Task.sleep(for: .milliseconds(130))
            await blink()
        case .slowBlink:
            await slowBlink()
        case .squint:
            await squint()
        case .flutter:
            await flutter()
        case .drowse:
            await drowse()
        case .lookAround(let fixations):
            await lookAround(fixations)
        case .doubleTake:
            await doubleTake()
        case .follow:
            await follow()
        case .roll:
            await roll()
        case .nod:
            await nod()
        case .shake:
            await shake()
        case .focus:
            await focus()
        case .drift:
            await drift()
        case .peek:
            await peek()
        case .scan:
            await scan()
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
        x = leaning(x, by: bias)

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
        move(
            Eye(lid: restLid, gaze: target),
            .easeOut(duration: Double.random(in: 0.045...0.07))
        )
    }

    /// Asymmetric on purpose: lids snap shut and drift open, and a blink with
    /// matching in and out timings is the other thing that reads as mechanical.
    private func blink() async {
        move(Eye(lid: 1, gaze: eye.gaze), .easeIn(duration: 0.06))
        try? await Task.sleep(for: .milliseconds(75))
        move(Eye(lid: restLid, gaze: eye.gaze), .easeOut(duration: 0.11))
    }

    /// A long, unhurried close, eased both ways rather than snapped shut. The
    /// one beat that reads as an expression rather than a reflex.
    private func slowBlink() async {
        move(Eye(lid: 1, gaze: eye.gaze, dilation: 0.94), .easeInOut(duration: 0.19))
        try? await Task.sleep(for: .milliseconds(220))
        move(Eye(lid: restLid, gaze: eye.gaze), .easeOut(duration: 0.26))
    }

    /// The lid halfway down and held there, pupil a hair narrower with it.
    /// Concentration, on a mark that has one moving part to say it with.
    private func squint() async {
        move(Eye(lid: 0.5, gaze: eye.gaze, dilation: 0.9), .easeOut(duration: 0.13))
        try? await Task.sleep(for: .milliseconds(Int.random(in: 380...720)))
        move(Eye(lid: restLid, gaze: eye.gaze), .easeOut(duration: 0.16))
    }

    /// Three fast half-blinks. Kept rare and kept partial: any faster, or all
    /// the way shut, and it stops being a flutter and becomes a rendering fault.
    private func flutter() async {
        for _ in 0..<3 {
            move(Eye(lid: 0.85, gaze: eye.gaze), .easeIn(duration: 0.05))
            try? await Task.sleep(for: .milliseconds(58))
            move(Eye(lid: restLid, gaze: eye.gaze), .easeOut(duration: 0.07))
            try? await Task.sleep(for: .milliseconds(72))
            guard !Task.isCancelled else { return }
        }
    }

    /// The lid sinks under its own weight over most of a second, gaze drifting
    /// down with it, then snaps back up. Nothing else here is slow enough for
    /// the recovery to land as having caught itself.
    private func drowse() async {
        move(
            Eye(lid: 0.62, gaze: CGSize(width: eye.gaze.width, height: 0.35), dilation: 0.92),
            .easeInOut(duration: 0.9)
        )
        try? await Task.sleep(for: .milliseconds(Int.random(in: 520...900)))
        guard !Task.isCancelled else { return }
        restLid = 0
        move(Eye(), .easeOut(duration: 0.09))
        try? await Task.sleep(for: .milliseconds(90))
        await blink()
    }

    /// A look away and straight back, then the same look again — held, and
    /// wider. The first one did not believe what it saw.
    private func doubleTake() async {
        guard !isAttentive else { return }
        let side: CGFloat = Bool.random() ? 1 : -1
        let away = CGSize(width: leaning(side * CGFloat.random(in: 0.7...1), by: bias), height: 0)

        saccade(to: away)
        try? await Task.sleep(for: .milliseconds(110))
        saccade(to: .zero)
        try? await Task.sleep(for: .milliseconds(Int.random(in: 90...150)))
        guard !isAttentive, !Task.isCancelled else { return }

        // Wider on the second look: whatever it was, it earned one.
        move(
            Eye(lid: restLid, gaze: away, dilation: 1.1),
            .easeOut(duration: Double.random(in: 0.045...0.07))
        )
        try? await Task.sleep(for: .milliseconds(Int.random(in: 420...700)))
        saccade(to: .zero)
        try? await Task.sleep(for: .milliseconds(70))
        await blink()
    }

    /// Smooth pursuit — the one kind of real eye movement that eases, because
    /// it is the one that has something to track. It catches the thing with a
    /// saccade, because the eye jumps to a target before it can follow it, and
    /// only then glides across and loses it at the far edge.
    private func follow() async {
        guard !isAttentive else { return }
        let from: CGFloat = Bool.random() ? -1 : 1
        let height = CGFloat.random(in: -0.2...0.2)

        saccade(to: CGSize(width: leaning(from * 0.95, by: bias), height: height))
        try? await Task.sleep(for: .milliseconds(Int.random(in: 120...220)))
        guard !isAttentive, !Task.isCancelled else { return }

        let glide = Double.random(in: 0.9...1.4)
        move(
            Eye(
                lid: restLid,
                gaze: CGSize(
                    width: leaning(-from * 0.95, by: bias),
                    height: height + CGFloat.random(in: -0.25...0.25)
                )
            ),
            .easeInOut(duration: glide)
        )
        try? await Task.sleep(for: .seconds(glide + 0.12))
        guard !Task.isCancelled else { return }
        saccade(to: .zero)
        try? await Task.sleep(for: .milliseconds(70))
        await blink()
    }

    /// One slow circuit of everything the eye can reach, eased between stops
    /// rather than jumped: this is one continuous movement, not a tour of
    /// fixations. The most obviously *performed* thing the mark does, so among
    /// the rarest — a mark that performs on a schedule stops being furniture
    /// and starts being a pet.
    private func roll() async {
        guard !isAttentive else { return }
        let direction: Double = Bool.random() ? 1 : -1

        for step in 0..<8 {
            let angle = Double(step) / 8 * 2 * .pi * direction
            let target = CGSize(
                width: leaning(CGFloat(cos(angle)) * 0.9, by: bias * 0.5),
                height: CGFloat(sin(angle)) * 0.85
            )
            restLid = target.height > 0.3 ? 0.18 : 0
            move(Eye(lid: restLid, gaze: target), .easeInOut(duration: 0.16))
            try? await Task.sleep(for: .milliseconds(150))
            guard !isAttentive, !Task.isCancelled else { break }
        }

        restLid = 0
        saccade(to: .zero)
        try? await Task.sleep(for: .milliseconds(70))
        await blink()
    }

    /// Two quick dips. The lid rides down with the gaze, which is what turns a
    /// vertical wobble into a yes.
    ///
    /// Allowed to run while somebody is hovering, unlike everything that
    /// wanders: this one is addressed to them.
    private func nod() async {
        let x = eye.gaze.width
        for _ in 0..<2 {
            saccade(to: CGSize(width: x, height: 0.55))
            try? await Task.sleep(for: .milliseconds(105))
            saccade(to: CGSize(width: x, height: -0.15))
            try? await Task.sleep(for: .milliseconds(115))
            guard !Task.isCancelled else { return }
        }
        saccade(to: .zero)
        try? await Task.sleep(for: .milliseconds(70))
    }

    /// Left, right, left, home. The counterpart to the nod, and the one beat
    /// that is faster than a look and slower than a twitch.
    private func shake() async {
        guard !isAttentive else { return }
        let side: CGFloat = Bool.random() ? 1 : -1

        for step in 0..<3 {
            let x = side * (step.isMultiple(of: 2) ? 0.62 : -0.62)
            saccade(to: CGSize(width: leaning(x, by: bias), height: 0))
            try? await Task.sleep(for: .milliseconds(95))
            guard !Task.isCancelled else { return }
        }

        saccade(to: .zero)
        try? await Task.sleep(for: .milliseconds(70))
        await blink()
    }

    /// The pupil contracts hard and locks dead centre. Reads as being looked
    /// at, which is the one thing this mark can do that a status light cannot.
    private func focus() async {
        move(Eye(lid: restLid, gaze: .zero, dilation: 0.78), .easeOut(duration: 0.14))
        try? await Task.sleep(for: .milliseconds(Int.random(in: 500...900)))
        guard !Task.isCancelled else { return }
        // Releases past its resting size before settling. A pupil that
        // contracts and simply returns reads as a redraw, not as letting go.
        move(Eye(lid: restLid, gaze: .zero, dilation: 1.07), .easeOut(duration: 0.12))
        try? await Task.sleep(for: .milliseconds(140))
        move(Eye(lid: restLid, gaze: .zero), .easeInOut(duration: 0.22))
    }

    /// The gaze wanders off with nothing to fix on and slowly comes back. The
    /// only aimless movement in the set, and the set needs one: everything else
    /// here is the eye doing something on purpose.
    private func drift() async {
        guard !isAttentive else { return }
        let height = CGFloat.random(in: -0.25...0.45)
        restLid = height > 0.3 ? 0.2 : 0

        move(
            Eye(
                lid: restLid,
                gaze: CGSize(width: leaning(CGFloat.random(in: -0.7...0.7), by: bias), height: height),
                dilation: 0.96
            ),
            .easeInOut(duration: 1.1)
        )
        try? await Task.sleep(for: .milliseconds(Int.random(in: 900...1600)))
        guard !isAttentive, !Task.isCancelled else { return }

        restLid = 0
        move(Eye(), .easeInOut(duration: 0.8))
        try? await Task.sleep(for: .milliseconds(820))
        await blink()
    }

    /// The lid drops *first*, and the look happens from under it. The order is
    /// the whole beat: look first and it is a squint with a glance in it.
    private func peek() async {
        guard !isAttentive else { return }
        let side: CGFloat = Bool.random() ? 1 : -1

        move(Eye(lid: 0.68, gaze: eye.gaze, dilation: 0.92), .easeOut(duration: 0.14))
        try? await Task.sleep(for: .milliseconds(90))
        move(
            Eye(
                lid: 0.68,
                gaze: CGSize(width: leaning(side * CGFloat.random(in: 0.75...1), by: bias), height: 0),
                dilation: 0.92
            ),
            .easeOut(duration: Double.random(in: 0.045...0.07))
        )
        try? await Task.sleep(for: .milliseconds(Int.random(in: 450...800)))
        saccade(to: .zero)
        try? await Task.sleep(for: .milliseconds(70))
        await blink()
    }

    /// Short even saccades marching one way, the way an eye crosses a line of
    /// text. Distinct from `lookAround`, which jumps wide and comes back.
    private func scan() async {
        guard !isAttentive else { return }
        let direction: CGFloat = Bool.random() ? 1 : -1
        let steps = Int.random(in: 3...5)

        saccade(to: CGSize(
            width: leaning(-direction * 0.9, by: bias),
            height: CGFloat.random(in: -0.1...0.1)
        ))
        try? await Task.sleep(for: .milliseconds(Int.random(in: 160...240)))

        for step in 1...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            saccade(to: CGSize(
                width: leaning(-direction * 0.9 + direction * 1.8 * progress, by: bias),
                height: CGFloat.random(in: -0.12...0.12)
            ))
            try? await Task.sleep(for: .milliseconds(Int.random(in: 130...210)))
            guard !isAttentive, !Task.isCancelled else { break }
        }

        saccade(to: .zero)
        try? await Task.sleep(for: .milliseconds(70))
        await blink()
    }

    // MARK: - Sleep

    /// Give up and close the eye.
    ///
    /// Not a beat: a three-second nap drawn at random is a twitch, not sleep.
    /// This is a *state* the mark falls into after minutes of nobody caring,
    /// and it is the cheapest the app ever gets — the loop keeps running only
    /// to stir, which is two moves every forty to ninety seconds against two to
    /// ten every four to twelve. The mascot that was supposed to be the energy
    /// risk is the one state that pays the budget back.
    ///
    /// The lid stops at 0.93 rather than 1. That sliver of pupil is the whole
    /// difference between a mark that is asleep and a window that has hung, and
    /// once the beats stop it is the only thing still saying the app is there.
    private func doze() {
        isAsleep = true
        asleepSince = ContinuousClock.now
        restLid = 0.93
        move(
            Eye(lid: 0.93, gaze: CGSize(width: 0, height: 0.12), dilation: 0.9),
            .easeInOut(duration: 1.6)
        )
    }

    /// One slow half-open and back. The entire job of this beat is to prove the
    /// window is not frozen, at the lowest price that does it.
    private func stir() async {
        move(Eye(lid: 0.72, gaze: eye.gaze, dilation: 0.9), .easeInOut(duration: 0.4))
        try? await Task.sleep(for: .milliseconds(Int.random(in: 260...420)))
        move(Eye(lid: 0.93, gaze: eye.gaze, dilation: 0.9), .easeInOut(duration: 0.5))
    }

    /// Somebody arrived. Snaps open wide and settles back — the overshoot on
    /// the pupil is what sells it as a start rather than a redraw.
    private func wake() async {
        let slept = asleepSince.map { $0.duration(to: ContinuousClock.now) } ?? .zero
        isAsleep = false
        asleepSince = nil
        awakeSince = ContinuousClock.now
        restLid = 0

        move(Eye(lid: 0, gaze: .zero, dilation: 1.16), .easeOut(duration: 0.12))
        try? await Task.sleep(for: .milliseconds(160))
        move(Eye(), .easeInOut(duration: 0.3))
        try? await Task.sleep(for: .milliseconds(240))
        await blink()

        // Only after a real sleep, and not every time. A yawn on every wake is
        // a mannerism, and a mannerism on a schedule stops being a surprise.
        if slept > .seconds(60), Int.random(in: 0..<100) < 45 {
            await yawn()
        }
    }

    /// A hard squeeze, then wide open and slowly back down.
    private func yawn() async {
        move(Eye(lid: 1, gaze: .zero, dilation: 0.84), .easeInOut(duration: 0.26))
        try? await Task.sleep(for: .milliseconds(400))
        move(Eye(lid: 0, gaze: .zero, dilation: 1.2), .easeOut(duration: 0.3))
        try? await Task.sleep(for: .milliseconds(340))
        move(Eye(), .easeInOut(duration: 0.45))
        try? await Task.sleep(for: .milliseconds(300))
        await blink()
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
/// A blink is two wakeups and the longest beat is ten over a second and a half,
/// so the busiest minute this can have is roughly thirty — still single figures
/// on average, still each with half a second of tolerance for macOS to coalesce.
///
/// Three things keep it there as the vocabulary grows. The expensive beats are
/// the *long* ones rather than the busy ones — an animated second is the
/// compositor kept awake, and `drift` alone is two of them — so on battery the
/// draw is filtered to `Beat.isFrugal`, and in Low Power Mode to the beats that
/// move the lid and nothing else. And after minutes of nobody looking the mark
/// stops altogether: see `IdleMarkAnimator.doze`, which is what makes the whole
/// set cost less over an idle hour than the three beats it grew out of.
struct IdleMark: View {
    /// Height of the mark in points. The width follows from `BrandGeometry`.
    var height: CGFloat = 16
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

    /// How far the pupil may travel from centre, in points.
    ///
    /// Measured from the room the shell actually leaves, rather than taken as
    /// a fraction of the pupil. The old version was the latter and came out at
    /// under three points of horizontal travel: the eye *was* looking around,
    /// it just never moved far enough for anybody to catch it doing so, which
    /// is indistinguishable from an animation that is not running. What is
    /// subtracted at the end is the margin that keeps the pupil off the inside
    /// of its own outline at full deflection.
    private var travel: CGSize {
        CGSize(
            width: max((width - eye) / 2 - height * 0.14, 0),
            height: max((height - eye) / 2 - height * 0.12, 0)
        )
    }

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

            // The pupil. Solid here and solid in the menu bar cut too — it is
            // the only part of the mark that is saying anything, so it is the
            // part that carries the weight in both places. The shell is what
            // differs: filled at 13% on the island's black, an outline up in
            // the bar where there is no black to sit on.
            Capsule(style: .continuous)
                .fill(Color.white.opacity(isAttentive ? 0.95 : 0.78))
                .frame(
                    width: eye * animator.eye.dilation,
                    height: max(eye * animator.eye.dilation * (1 - animator.eye.lid * 0.86), 1)
                )
                .offset(
                    x: animator.eye.gaze.width * travel.width,
                    y: animator.eye.gaze.height * travel.height
                )
                // Scoped to the eye, with the animator's own timing. See
                // `IdleMarkAnimator.motion` for why it is not `withAnimation`.
                .animation(animator.motion, value: animator.eye)
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
        .onChange(of: reduceMotion) { _, reduced in
            // A live setting, not a launch-time one. Turning Reduce Motion back
            // off used to leave a dead eye until something happened to recreate
            // the view, which under a notch is close to never.
            if reduced {
                animator.stop()
            } else if !isSuspended {
                animator.start(reduceMotion: false)
            }
        }
        .onChange(of: isAttentive) { _, attentive in animator.attend(attentive) }
        .onChange(of: position) { _, new in animator.bias = new.gazeBias }
        .accessibilityLabel(Text("Runway — nothing running"))
        .help("Nothing is running. Hover for the last update.")
    }
}
