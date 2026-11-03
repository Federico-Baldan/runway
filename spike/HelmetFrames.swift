// A helmet at an instant half way through a move, and a gesture as a strip of
// such instants: what SwiftUI would draw, closely enough to be looked at.
//
// SwiftUI does not animate a channel. It animates each PROPERTY of each part (an
// opacity, an offset, a rotation, a frame) from the value it had to the value it
// will have, along the step's curve, and knows nothing of the tent a pulse draws
// over the channel. So a frame between two steps is the straight line between
// the pose at the start of the step and the pose at its end, eased. That is also
// why a gesture has to walk a pulsed part's corners, and why this file draws it
// that way and not as a function of the channel.
//
// The curves are the usual approximations (the real ones are cubic Béziers), and
// the spring is drawn as an ease-out: the frames show the shape of the move and
// not its exact speed.

// CGRect, CGPoint and CGSize come with their members only from CoreGraphics on
// macOS, which has no such module on Linux, where Foundation has them all.
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

struct HelmetPose {
    struct Part {
        var opacity: CGFloat, dx: CGFloat, dy: CGFloat, rotation: CGFloat, scale: CGFloat
    }

    var eyes: [CGRect]
    var led: CGFloat
    var gazeX: CGFloat
    var gazeY: CGFloat
    var plateY: CGFloat
    var flash: CGFloat
    var parts: [Part]

    init(_ spec: HelmetSpec, _ s: HelmetState) {
        eyes = spec.eyeRects(s)
        led = s.led
        gazeX = s.gazeX
        gazeY = s.gazeY
        plateY = spec.plateOffsetY(s)
        flash = s.gesture(spec.plate.flashGesture)
        parts = spec.dynamics.map {
            let m = spec.motion(of: $0, in: s)
            return Part(opacity: m.opacity, dx: m.dx, dy: m.dy, rotation: m.rotation, scale: m.scale)
        }
    }

    private init(eyes: [CGRect], led: CGFloat, gazeX: CGFloat, gazeY: CGFloat, plateY: CGFloat, flash: CGFloat, parts: [Part]) {
        self.eyes = eyes; self.led = led; self.gazeX = gazeX; self.gazeY = gazeY
        self.plateY = plateY; self.flash = flash; self.parts = parts
    }

    /// The straight line from `a` to `b`, `t` of the way.
    static func lerp(_ a: HelmetPose, _ b: HelmetPose, _ t: CGFloat) -> HelmetPose {
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
        let eyes = zip(a.eyes, b.eyes).map { p, q in
            CGRect(x: mix(p.minX, q.minX), y: mix(p.minY, q.minY), width: mix(p.width, q.width), height: mix(p.height, q.height))
        }
        let parts = zip(a.parts, b.parts).map { p, q in
            Part(opacity: mix(p.opacity, q.opacity), dx: mix(p.dx, q.dx), dy: mix(p.dy, q.dy),
                 rotation: mix(p.rotation, q.rotation), scale: mix(p.scale, q.scale))
        }
        return HelmetPose(eyes: eyes, led: mix(a.led, b.led), gazeX: mix(a.gazeX, b.gazeX), gazeY: mix(a.gazeY, b.gazeY),
                          plateY: mix(a.plateY, b.plateY), flash: mix(a.flash, b.flash), parts: parts)
    }
}

extension HelmetVerify {
    static func eased(_ curve: SignatureStep.Curve, _ u: CGFloat) -> CGFloat {
        switch curve {
        case .linear: return u
        case .easeIn: return u * u
        case .easeOut, .spring: return 1 - (1 - u) * (1 - u)
        case .easeInOut: return u < 0.5 ? 2 * u * u : 1 - 2 * (1 - u) * (1 - u)
        case .instant: return 1
        }
    }

    /// Where a gesture is at `time` seconds after its first step, as a pose.
    static func pose(of steps: [SignatureStep], at time: Double, in spec: HelmetSpec) -> HelmetPose {
        var state = HelmetState.rest
        var clock = 0.0
        for step in steps {
            var next = state
            if let level = step.level, next.gestures.indices.contains(step.channel) { next.gestures[step.channel] = level }
            if let g = step.gaze { next.gazeX = g.width; next.gazeY = g.height }
            if let dilation = step.dilation { next.dilation = dilation }
            let end = clock + step.wait
            if time < end || end == clock && time <= clock {
                let local = time - clock
                let u: CGFloat = step.duration <= 0 ? 1 : CGFloat(min(max(local / step.duration, 0), 1))
                return HelmetPose.lerp(HelmetPose(spec, state), HelmetPose(spec, next), eased(step.curve, u))
            }
            state = next
            clock = end
        }
        return HelmetPose(spec, state)
    }

    /// Every gesture of every helmet as `count` frames from its first instant to its last, as SVG,
    /// and a manifest of what each frame's time is.
    static func writeFrames(into directory: String, count: Int) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var manifest: [String] = []
        for style in AvatarStyle.allCases {
            guard let spec = style.helmet else { continue }
            var gestureEntries: [String] = []
            for (index, steps) in HelmetSignature.gestures(for: style).enumerated() {
                let wall = steps.reduce(0.0) { $0 + $1.wait }
                var times: [Int] = []
                for k in 0..<count {
                    let t = wall * Double(k) / Double(max(count - 1, 1))
                    times.append(Int((t * 1000).rounded()))
                    let frame = pose(of: steps, at: t, in: spec)
                    let path = "\(directory)/\(style.rawValue)-g\(index)-\(k).svg"
                    do {
                        try render(spec, frame).write(toFile: path, atomically: true, encoding: .utf8)
                    } catch {
                        print("  FAIL  could not write \(path): \(error)")
                        failures += 1
                    }
                }
                let cost = HelmetSignature.cost(of: steps)
                gestureEntries.append("{\"ms\": \(times), \"moves\": \(cost.moves), \"animated\": \(String(format: "%.2f", cost.seconds)), \"wall\": \(String(format: "%.2f", wall))}")
            }
            manifest.append("\"\(style.rawValue)\": [\(gestureEntries.joined(separator: ", "))]")
            print("  wrote \(style.rawValue) × \(gestureEntries.count) gestures × \(count) frames")
        }
        try? "{\(manifest.joined(separator: ",\n"))}\n".write(toFile: "\(directory)/manifest.json", atomically: true, encoding: .utf8)
    }
}
