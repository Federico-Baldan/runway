import Foundation

/// One move of a gesture.
///
/// A gesture is something a helmet does that the others do not: the gold visor
/// lifts and taps back, the lamp flashes, a glint sweeps the glass, the tab
/// flicks, the chevrons strobe. Each helmet has a few. A gesture is written
/// down as a short list of these steps and played by the animator, which is why
/// it can be checked without a screen — what it costs, and that it always
/// leaves the helmet exactly as it found it, are facts about the list and
/// nothing else.
struct SignatureStep: Sendable, Equatable {
    enum Curve: Sendable, Equatable {
        case easeOut, easeIn, easeInOut, linear
        /// A settle with a little bounce, for a visor that is let go.
        case spring
        /// No visible in-between: a one-millisecond move, for the moment a
        /// gesture ends and must not be seen running backwards (a sweep that
        /// reached the right edge goes back to the left without crossing the
        /// glass).
        case instant
    }

    /// How long the move takes. Zero for an `.instant` one.
    var duration: Double
    /// How long to wait after it before the next, with nothing moving.
    var hold: Double = 0
    var curve: Curve = .easeOut
    /// Which of the gesture channels `level` is for. A gesture drives its own.
    var channel = 0
    var level: CGFloat?
    var gaze: CGSize?
    var dilation: CGFloat?
    /// Takes the eye somewhere. Skipped while somebody is hovering the island:
    /// the eye is looking at them and must not wander off — the same rule
    /// `lookAround` follows.
    var looksAway = false

    /// Seconds the compositor is kept busy by this move.
    var animatedSeconds: Double { curve == .instant ? 0 : duration }

    /// How long the animator waits before the next step: the move itself, then
    /// the hold. A step that is not waited for is replaced by the next one in
    /// the same turn, before SwiftUI has drawn a single frame of it, so a
    /// gesture whose steps have no hold would never be seen at all.
    var wait: Double { animatedSeconds + hold }
}

enum HelmetSignature {
    /// How many gestures a helmet can have: one per channel.
    static var slots: Int { HelmetState.gestureSlots }

    /// The gestures a style makes, none for the original eye. Built once: the
    /// animator asks for them when it draws a beat and again when it plays one.
    static func gestures(for style: AvatarStyle) -> [[SignatureStep]] {
        table[style] ?? []
    }

    private static let table: [AvatarStyle: [[SignatureStep]]] = Dictionary(
        uniqueKeysWithValues: AvatarStyle.allCases.map { ($0, build($0)) }
    )

    /// A run of steps that walks a channel through the levels where each part of
    /// a chase has its peak, one step per part, then drops it to 0 unseen.
    ///
    /// A chase cannot be one move from 0 to 1: SwiftUI animates the opacity of
    /// each part from where it was to where it will be, in a straight line, so a
    /// part that must light in the middle of the move would never light. Stepping
    /// the channel through the peaks makes each part's straight lines between
    /// steps add up to its own tent. The last level (1) lights nothing, so the
    /// reset to 0 cannot be seen.
    private static func walk(
        _ levels: [CGFloat], channel: Int, each: Double, curve: SignatureStep.Curve = .linear
    ) -> [SignatureStep] {
        levels.map { SignatureStep(duration: each, curve: curve, channel: channel, level: $0) }
            + [SignatureStep(duration: 0, curve: .instant, channel: channel, level: 0)]
    }

    private static func build(_ style: AvatarStyle) -> [[SignatureStep]] {
        switch style {
        case .classic:
            return []

        case .apollo:
            return [
                // The visor comes up off the glass, waits a beat, and is let go.
                [
                    SignatureStep(duration: 0.16, hold: 0.18, curve: .easeOut, level: 1),
                    // A spring keeps moving until it settles, so it is counted at
                    // that, not at the 0.2s a plain ease would take.
                    SignatureStep(duration: 0.28, curve: .spring, level: 0),
                ],
                // A light runs along the orange band: three spans, peaks at 1/4, 1/2, 3/4.
                walk([0.25, 0.5, 0.75, 1], channel: 1, each: 0.105),
                // A glint slides over the gold strip.
                [
                    SignatureStep(duration: 0.38, curve: .easeInOut, channel: 2, level: 1),
                    SignatureStep(duration: 0, curve: .instant, channel: 2, level: 0),
                ],
                // The latches at the sides light, left then right, as the eyes glance at
                // each. The left one peaks at 1/4 and is gone at 1/2, the right peaks at 3/4.
                [
                    SignatureStep(duration: 0.08, hold: 0.05, curve: .easeOut, channel: 3, level: 0.25, gaze: CGSize(width: -0.8, height: 0), looksAway: true),
                    SignatureStep(duration: 0.06, curve: .easeOut, channel: 3, level: 0.5),
                    SignatureStep(duration: 0.08, hold: 0.05, curve: .easeOut, channel: 3, level: 0.75, gaze: CGSize(width: 0.8, height: 0), looksAway: true),
                    SignatureStep(duration: 0.06, curve: .easeOut, channel: 3, level: 1, gaze: .zero, looksAway: true),
                    SignatureStep(duration: 0, curve: .instant, channel: 3, level: 0),
                ],
            ]

        case .orlan:
            return [
                // The lamp blinks twice, then stays on while the eyes narrow to
                // focus the camera, and goes off.
                [
                    SignatureStep(duration: 0.05, hold: 0.09, curve: .easeOut, level: 1),
                    SignatureStep(duration: 0.07, hold: 0.08, curve: .easeIn, level: 0),
                    SignatureStep(duration: 0.06, hold: 0.24, curve: .easeOut, level: 1, dilation: 0.85),
                    SignatureStep(duration: 0.18, curve: .easeOut, level: 0, dilation: 1),
                ],
                // A light runs once round the porthole: four quarters, peaks at 1/5 to 4/5.
                walk([0.2, 0.4, 0.6, 0.8, 1], channel: 1, each: 0.09),
                // The eyes glance at the camera, which clicks twice. The ring of
                // light peaks at 1/2 and the lens at 1, so each click passes through both.
                [
                    SignatureStep(duration: 0.06, hold: 0.04, curve: .easeOut, gaze: CGSize(width: 0.85, height: 0), looksAway: true),
                    SignatureStep(duration: 0.03, curve: .easeOut, channel: 2, level: 0.5),
                    SignatureStep(duration: 0.03, hold: 0.06, curve: .easeOut, channel: 2, level: 1),
                    SignatureStep(duration: 0.03, curve: .easeIn, channel: 2, level: 0.5),
                    SignatureStep(duration: 0.03, hold: 0.06, curve: .easeOut, channel: 2, level: 1),
                    SignatureStep(duration: 0.12, curve: .easeOut, channel: 2, level: 0, gaze: .zero, looksAway: true),
                ],
                // The lamp lights and its beam sweeps down the face, the eyes following
                // it. Both are brightest half way, so the channel passes through 1/2.
                [
                    SignatureStep(duration: 0.05, hold: 0.02, curve: .easeOut, gaze: CGSize(width: 0.4, height: -0.6), looksAway: true),
                    SignatureStep(duration: 0.14, curve: .linear, channel: 3, level: 0.5, gaze: CGSize(width: 0.4, height: 0), looksAway: true),
                    SignatureStep(duration: 0.14, curve: .linear, channel: 3, level: 1, gaze: CGSize(width: 0.4, height: 0.6), looksAway: true),
                    SignatureStep(duration: 0, curve: .instant, channel: 3, level: 0),
                    SignatureStep(duration: 0.08, curve: .easeOut, gaze: .zero, looksAway: true),
                ],
            ]

        case .stealth:
            return [
                // The eyes jump to the left edge, then follow a glint across the
                // glass to the right and come home. The pinstripe is brightest as
                // the glint crosses the middle, so the sweep passes through 1/2,
                // in two linear halves so the glint and the eyes keep one speed.
                [
                    SignatureStep(duration: 0.05, hold: 0.06, curve: .easeOut, gaze: CGSize(width: -0.9, height: 0), looksAway: true),
                    SignatureStep(duration: 0.17, curve: .linear, level: 0.5, gaze: .zero, looksAway: true),
                    SignatureStep(duration: 0.17, curve: .linear, level: 1, gaze: CGSize(width: 0.9, height: 0), looksAway: true),
                    SignatureStep(duration: 0, curve: .instant, level: 0),
                    SignatureStep(duration: 0.08, curve: .easeOut, gaze: .zero, looksAway: true),
                ],
                // A line of light scans the window, top to bottom, and the eyes narrow to it.
                // The line is brightest half way down, so the channel passes through 1/2.
                [
                    SignatureStep(duration: 0.19, curve: .linear, channel: 1, level: 0.5, dilation: 0.85),
                    SignatureStep(duration: 0.19, curve: .linear, channel: 1, level: 1),
                    SignatureStep(duration: 0, curve: .instant, channel: 1, level: 0),
                    SignatureStep(duration: 0.10, curve: .easeOut, dilation: 1),
                ],
                // The eyes read down the glass while the visor strip flashes.
                [
                    SignatureStep(duration: 0.05, hold: 0.10, curve: .easeOut, gaze: CGSize(width: 0, height: -0.8), looksAway: true),
                    SignatureStep(duration: 0.06, hold: 0.06, curve: .easeOut, channel: 2, level: 1),
                    SignatureStep(duration: 0.05, hold: 0.10, curve: .easeOut, gaze: CGSize(width: 0, height: 0.8), looksAway: true),
                    SignatureStep(duration: 0.08, curve: .easeIn, channel: 2, level: 0),
                    SignatureStep(duration: 0.08, curve: .easeOut, gaze: .zero, looksAway: true),
                ],
                // Targeting brackets close on the right eye while the eyes narrow.
                [
                    SignatureStep(duration: 0.12, hold: 0.16, curve: .easeOut, channel: 3, level: 1, dilation: 0.8),
                    SignatureStep(duration: 0.12, curve: .easeOut, channel: 3, level: 0, dilation: 1),
                ],
            ]

        case .papaya:
            return [
                // The tear-off tab flicks twice, and the sun visor dips.
                [
                    SignatureStep(duration: 0.07, hold: 0.05, curve: .easeOut, level: 1),
                    SignatureStep(duration: 0.10, hold: 0.06, curve: .easeIn, level: 0),
                    SignatureStep(duration: 0.07, hold: 0.04, curve: .easeOut, level: 1),
                    SignatureStep(duration: 0.12, curve: .easeIn, level: 0),
                ],
                // The number shines, twice.
                [
                    SignatureStep(duration: 0.06, hold: 0.03, curve: .easeOut, channel: 1, level: 1),
                    SignatureStep(duration: 0.10, hold: 0.05, curve: .easeIn, channel: 1, level: 0),
                    SignatureStep(duration: 0.06, hold: 0.03, curve: .easeOut, channel: 1, level: 1),
                    SignatureStep(duration: 0.12, curve: .easeIn, channel: 1, level: 0),
                ],
                // The engine: the eyes shiver and the cheek flash lights.
                [
                    SignatureStep(duration: 0.03, hold: 0.015, curve: .easeOut, channel: 2, level: 1, gaze: CGSize(width: -0.8, height: 0), looksAway: true),
                    SignatureStep(duration: 0.03, hold: 0.015, curve: .easeOut, gaze: CGSize(width: 0.8, height: 0), looksAway: true),
                    SignatureStep(duration: 0.03, hold: 0.015, curve: .easeOut, gaze: CGSize(width: -0.8, height: 0), looksAway: true),
                    SignatureStep(duration: 0.03, hold: 0.015, curve: .easeOut, gaze: CGSize(width: 0.8, height: 0), looksAway: true),
                    SignatureStep(duration: 0.12, curve: .easeOut, channel: 2, level: 0, gaze: .zero, looksAway: true),
                ],
                // A wink: a lid slides down over the left eye, stays, and lifts.
                [
                    SignatureStep(duration: 0.07, hold: 0.16, curve: .easeOut, channel: 3, level: 1),
                    SignatureStep(duration: 0.12, curve: .easeInOut, channel: 3, level: 0),
                ],
            ]

        case .endurance:
            // A pit-lane strobe: three flashes.
            var strobe: [SignatureStep] = []
            for flash in 0..<3 {
                strobe.append(SignatureStep(duration: 0.04, hold: 0.07, curve: .linear, level: 1))
                strobe.append(SignatureStep(duration: 0.04, hold: flash == 2 ? 0 : 0.07, curve: .linear, level: 0))
            }
            return [
                strobe,
                // The sun strip dips and the eyes narrow behind it.
                [
                    SignatureStep(duration: 0.14, hold: 0.18, curve: .easeOut, channel: 1, level: 1, dilation: 0.85),
                    SignatureStep(duration: 0.16, curve: .easeIn, channel: 1, level: 0, dilation: 1),
                ],
                // A light runs along the chevrons: two halves, peaks at 1/3 and 2/3.
                walk([1.0 / 3, 2.0 / 3, 1], channel: 2, each: 0.13),
                // The lights of a car behind fill the visor and the eyes look away.
                [
                    SignatureStep(duration: 0.04, hold: 0.14, curve: .easeOut, channel: 3, level: 1, gaze: CGSize(width: -0.6, height: 0.7), looksAway: true),
                    SignatureStep(duration: 0.26, curve: .easeOut, channel: 3, level: 0, gaze: .zero, looksAway: true),
                ],
            ]
        }
    }

    /// What one gesture costs, counted the way the animator counts every beat:
    /// how many times it moves something, and how many seconds the compositor
    /// is kept busy doing it. Those two numbers are what decide whether it is
    /// allowed on battery (see `IdleMarkAnimator.Beat.isFrugal`).
    static func cost(of steps: [SignatureStep]) -> (moves: Int, seconds: Double) {
        (steps.count, steps.reduce(0) { $0 + $1.animatedSeconds })
    }

    static func cost(for style: AvatarStyle, gesture index: Int) -> (moves: Int, seconds: Double) {
        let all = gestures(for: style)
        return all.indices.contains(index) ? cost(of: all[index]) : (0, 0)
    }

    /// Where a gesture leaves things, assuming it began at rest: every channel,
    /// the gaze and the dilation after the last step. A gesture that does not
    /// end with all channels at 0, the gaze at the centre and the dilation at 1
    /// would leave a helmet with its lamp lit or its eyes off to one side until
    /// the next beat happened to fix it.
    static func endState(of steps: [SignatureStep]) -> (channels: [CGFloat], gaze: CGSize, dilation: CGFloat) {
        var channels = [CGFloat](repeating: 0, count: slots)
        var gaze = CGSize.zero, dilation: CGFloat = 1
        for step in steps {
            if let level = step.level, channels.indices.contains(step.channel) { channels[step.channel] = level }
            if let g = step.gaze { gaze = g }
            if let d = step.dilation { dilation = d }
        }
        return (channels, gaze, dilation)
    }
}
