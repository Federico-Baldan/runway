// Do the helmets hold together, and are their gestures cheap enough for battery?
//
// Everything a helmet is — its outlines, colours, how the visor and the LED eyes
// move, and the little gesture each one makes on its own — is plain data in
// Foundation-only files, so it can be checked without a screen, and drawn to SVG
// to be looked at. `HelmetView` is only the interpreter of this data.
//
//   swiftc -o /tmp/helmet spike/HelmetVerify.swift \
//       Sources/Runway/UI/AvatarStyle.swift Sources/Runway/UI/HelmetGeometry.swift \
//       Sources/Runway/UI/HelmetSpec.swift Sources/Runway/UI/HelmetSignature.swift \
//       && /tmp/helmet
//
// Add `svg <directory>` to also write each helmet in five poses as SVG.

// CGRect, CGPoint and CGSize come with their members only from CoreGraphics on
// macOS, which has no such module on Linux, where Foundation has them all.
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

@main
enum HelmetVerify {
    /// Single-threaded, written only from `check`; `nonisolated(unsafe)` says so
    /// to Swift 6's checker, which cannot know it.
    nonisolated(unsafe) static var failures = 0

    static func check(_ label: String, _ condition: Bool) {
        if condition {
            print("  ok    \(label)")
        } else {
            print("  FAIL  \(label)")
            failures += 1
        }
    }

    static func main() {
        let helmets = AvatarStyle.allCases.filter(\.isHelmet)

        print("── the styles ──")
        check("the original eye is not a helmet and has no spec", AvatarStyle.classic.helmet == nil)
        check("every helmet has a spec", helmets.allSatisfy { $0.helmet != nil })
        check("a fresh install gets a helmet", AvatarStyle.default.isHelmet)
        check("five helmets", helmets.count == 5)
        check("every style has a name and a tooltip", AvatarStyle.allCases.allSatisfy { !$0.title.isEmpty && !$0.summary.isEmpty })
        check("raw values are stable (they are stored in UserDefaults)",
              AvatarStyle.allCases.map(\.rawValue) == ["classic", "apollo", "orlan", "stealth", "papaya", "endurance"])

        print()
        print("── path builders ──")
        let box = HShape.box(cx: 5, cy: -3, width: 20, height: 10)
        check("a square-cornered box is four points", box.count == 5)
        let round = HShape.box(cx: 0, cy: 0, width: 20, height: 10, radius: 99)
        check("a radius larger than the box is clamped, not turned inside out", pointsOf(round).allSatisfy { abs($0.x) <= 10.001 && abs($0.y) <= 5.001 })
        let open = HShape.smooth([(0, 0), (10, 5), (20, 0)])
        check("an open curve starts and ends on its points", endpoints(open).first == CGPoint(x: 0, y: 0) && endpoints(open).last == CGPoint(x: 20, y: 0))
        check("a closed curve ends with a close", HShape.smooth([(0, 0), (10, 5), (20, 0)], closed: true).last == .close)
        let shell = HelmetSpec.shell
        check("the silhouette fits the notch exactly", bounds(shell) == CGRect(x: -156, y: -112, width: 312, height: 224))
        check("the notch is 78:56, the same aspect as BrandGeometry", HelmetSpec.designWidth / HelmetSpec.designHeight == 78.0 / 56.0)

        for style in helmets {
            guard let spec = style.helmet else { continue }
            print()
            print("── \(style.title) ──")

            let window = bounds(spec.window.path)
            check("the window sits inside the shell", shell.isEmpty == false && bounds(shell).contains(window))
            check("the visor is wider than the window it covers", spec.plateWidth >= window.width)
            check("the visor's travel matches the window", abs(spec.window.top - window.minY) <= 12 && abs(spec.window.bottom - window.maxY) <= 12)

            // The visor.
            let open = spec.plateEdgeY(.rest)
            var closed = HelmetState.rest
            closed.lid = 1
            check("lid shut, the visor's edge is at the bottom of the window", abs(spec.plateEdgeY(closed) - spec.window.bottom) < 0.001)
            var previous = -CGFloat.infinity
            var monotone = true
            for step in 0...10 {
                var s = HelmetState.rest
                s.lid = CGFloat(step) / 10
                let y = spec.plateEdgeY(s)
                if y < previous { monotone = false }
                previous = y
            }
            check("the visor only ever moves down as the lid closes", monotone)
            check("open, it rests where the design says (\(open))", abs(open - (spec.window.top + spec.window.restFraction * (spec.window.bottom - spec.window.top))) < 0.001)
            var lifted = HelmetState.rest
            lifted.gestures[spec.visorGesture] = 1
            if spec.raisesVisor {
                check("the signature lifts the visor off the glass", abs(spec.plateEdgeY(lifted) - spec.window.top) < 0.001)
            } else if spec.visorNudge > 0 {
                let dipped = spec.plateEdgeY(lifted)
                check("the signature dips the visor into the window", dipped > open && dipped < spec.window.bottom)
                var shut = lifted
                shut.lid = 1
                check("a dipped visor still closes all the way", abs(spec.plateEdgeY(shut) - spec.window.bottom) < 0.001)
            } else {
                check("the signature leaves the visor alone", spec.plateEdgeY(lifted) == open)
            }
            check("at rest the visor needs no offset", spec.plateOffsetY(.rest) == 0)

            // The eyes, at every extreme.
            var inside = true
            for gx: CGFloat in [-1, 0, 1] {
                for gy: CGFloat in [-1, 0, 1] {
                    for dilation: CGFloat in [0.6, 1, 1.35] {
                        var s = HelmetState.rest
                        s.gazeX = gx; s.gazeY = gy; s.dilation = dilation
                        for rect in spec.eyeRects(s) where !window.insetBy(dx: -0.5, dy: -0.5).contains(rect) { inside = false }
                    }
                }
            }
            check("the LEDs never leave the window, at any gaze or dilation", inside)
            let centred = spec.eyeRects(.rest)
            check("two eyes, mirrored about the centre", centred.count == 2 && abs(centred[0].midX + centred[1].midX) < 0.001)
            var wide = HelmetState.rest
            wide.dilation = 2
            check("dilation is capped, so a wide eye cannot swallow the window", spec.eyeRects(wide)[0].width <= spec.eyes.width * 1.25 + 0.001)
            var looking = HelmetState.rest
            looking.gazeX = 1
            check("looking right moves both LEDs right by the same travel", abs((spec.eyeRects(looking)[0].midX - centred[0].midX) - spec.eyes.travelX) < 0.001)

            // The parts that answer to a channel.
            check("every dynamic part has something to draw", spec.dynamics.allSatisfy { !$0.draws.isEmpty })
            for part in spec.dynamics {
                var on = HelmetState.rest
                on.led = 1
                on.gestures = [CGFloat](repeating: 1, count: HelmetState.gestureSlots)
                // A pulse is full only at its own centre, so look there.
                if let pulse = part.pulse, case .gesture(let index) = part.channel { on.gestures[index] = pulse.center }
                // At rest nothing a gesture lights may be lit.
                if case .gesture = part.channel, part.opacity.from == 0 {
                    check("a \(part.channel) part that lights is dark at rest", spec.motion(of: part, in: .rest).opacity == 0)
                }
                let motion = spec.motion(of: part, in: on)
                if part.pulse == nil {
                    check("a \(part.channel) part reaches the end of its ramp",
                          abs(motion.opacity - part.opacity.to) < 0.001 && abs(motion.scale - part.scale.to) < 0.001 && abs(motion.rotation - part.rotation.to) < 0.001)
                } else {
                    check("a pulsed part is at full strength at its centre", abs(motion.opacity - part.opacity.to) < 0.001)
                }
            }

            // Legible at the size the notch draws it: a dark shell on black is
            // 1.1 to 1.5 times the black, a pinstripe at 24 points is under a
            // device pixel, and a screw is a speck.
            let notchPPU: CGFloat = style.restHeight / HelmetSpec.designHeight
            let pixel = HelmetSpec.smallestFeature
            for layer in [HelmetLayerID.below, .above, .highlights] {
                let drawn = spec.draws(for: layer, pointsPerUnit: notchPPU)
                check("\(layer): no stroke is thinner than a device pixel at the notch's size",
                      drawn.allSatisfy { $0.stroke == nil || $0.strokeWidth * notchPPU >= pixel - 0.0001 })
                check("\(layer): no filled speck is smaller than a device pixel at the notch's size",
                      drawn.allSatisfy { $0.stroke != nil || $0.fill == nil || HelmetSpec.featureSize(of: $0.path) * notchPPU >= pixel - 0.0001 })
                check("\(layer): at the design size nothing is left out", spec.draws(for: layer, pointsPerUnit: 1).count == spec.draws(for: layer).count)
            }
            check("the shell and the livery survive the rules (the shell, the shadow and a light at least)",
                  spec.draws(for: .below, pointsPerUnit: notchPPU).count >= 3)
            let edge = spec.draws(for: .edge, pointsPerUnit: notchPPU)
            check("the edge light is one stroke, clipped to the shell, at least a device pixel wide inside it",
                  edge.count == 1 && edge[0].clipToShell && edge[0].strokeWidth * notchPPU / 2 >= pixel)
            // Relative luminance of the light over the notch's black, which is what it sits against.
            func luminance(_ c: HColor) -> Double {
                func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
                return 0.2126 * lin(c.red * c.alpha) + 0.7152 * lin(c.green * c.alpha) + 0.0722 * lin(c.blue * c.alpha)
            }
            let ratio = (luminance(spec.edge) + 0.05) / 0.05
            print("  \(style.rawValue): edge light is \(String(format: "%.1f", ratio)):1 against black, shell \(String(format: "%.2f", (luminance(HColor(0x2B2D32)) + 0.05) / 0.05)):1 for comparison")
            check("the edge light is at least 3:1 against the black of the notch (WCAG 1.4.11)", ratio >= 3)

            // The gestures.
            let gestures = HelmetSignature.gestures(for: style)
            check("it has at least one gesture, and no more than there are channels", !gestures.isEmpty && gestures.count <= HelmetState.gestureSlots)
            for (index, steps) in gestures.enumerated() {
                let cost = HelmetSignature.cost(of: steps)
                let end = HelmetSignature.endState(of: steps)
                let wall = steps.reduce(0.0) { $0 + $1.wait }
                // What the view can see. The animator waits `wait` after a step and
                // only then moves on, so a level that is overwritten inside the same
                // turn is never drawn: only the level at the end of each turn counts.
                var level: CGFloat = 0
                var seen: [CGFloat] = [0]
                // The straight runs SwiftUI draws: from the level a step starts at to
                // the one it ends at, for every step that is not an instant reset.
                var runs: [(from: CGFloat, to: CGFloat)] = []
                // The level an instant reset to 0 cuts off, if the gesture ends that way.
                var cutOff: CGFloat?
                for step in steps {
                    if let l = step.level {
                        if step.curve == .instant {
                            if l == 0 && level > 0 { cutOff = level }
                        } else {
                            runs.append((level, l))
                        }
                        level = l
                    }
                    if step.wait > 0 { seen.append(level) }
                }
                let channelsUsed = Set(steps.compactMap { $0.level == nil ? nil : $0.channel })
                let shown = spec.dynamics.contains { if case .gesture(let c) = $0.channel { return channelsUsed.contains(c) } else { return false } }
                    || (channelsUsed.contains(spec.visorGesture) && (spec.raisesVisor || spec.visorNudge > 0))
                    || (channelsUsed.contains(spec.plate.flashGesture) && spec.plate.edgeFlash != nil)
                print(String(format: "  gesture %d: %d moves, %.2fs animated, %.2fs on the clock", index, cost.moves, cost.seconds, wall))
                check("gesture \(index) is not empty", !steps.isEmpty)
                check("gesture \(index) drives a channel only this gesture owns", channelsUsed.count <= 1 && channelsUsed.allSatisfy { $0 == index })
                check("gesture \(index) shows on something: a part, the visor or the edge", channelsUsed.isEmpty || shown)
                check("gesture \(index) is cheap enough for battery: at most 6 moves and half a second animated", cost.moves <= 6 && cost.seconds <= 0.5)
                check("gesture \(index) ends with every channel back at 0", end.channels.allSatisfy { $0 == 0 })
                check("gesture \(index) ends with the gaze back at the centre", end.gaze == .zero)
                check("gesture \(index) ends with the eyes back at their resting size", end.dilation == 1)
                check("gesture \(index) keeps its channel inside 0...1", steps.allSatisfy { ($0.level ?? 0) >= 0 && ($0.level ?? 0) <= 1 })
                check("gesture \(index): anything that moves the gaze gives way to a hover", steps.allSatisfy { $0.gaze == nil || $0.looksAway })
                check("gesture \(index): no single wait is long (it must not hold the beat loop)", steps.allSatisfy { $0.hold <= 0.3 && $0.duration <= 0.45 })
                check("gesture \(index): an instant step costs nothing", steps.filter { $0.curve == .instant }.allSatisfy { $0.animatedSeconds == 0 })
                check("gesture \(index) is over inside 1.2s", wall <= 1.2)
                check("gesture \(index) is SEEN: its channel is away from rest at the end of some turn", channelsUsed.isEmpty || seen.contains { $0 > 0.001 })
                for part in spec.dynamics {
                    guard case .gesture(let c) = part.channel, channelsUsed.contains(c) else { continue }
                    // A part that is lit by opacity must be dark where an instant reset
                    // cuts the gesture off, or it would pop out of existence.
                    if let top = cutOff, part.opacity.from == 0, part.opacity.to > 0 {
                        var at = HelmetState.rest
                        at.gestures[c] = top
                        check("gesture \(index): a lit part is dark where the instant reset cuts in (level \(top))", spec.motion(of: part, in: at).opacity < 0.001)
                    }
                    if let pulse = part.pulse {
                        // SwiftUI draws a straight line between two levels, so a tent
                        // is only right if the walk visits all of its corners.
                        let corners = [pulse.center - pulse.width, pulse.center, pulse.center + pulse.width].filter { $0 > 0.001 && $0 < 1.001 }
                        let visited = corners.allSatisfy { corner in seen.contains { abs($0 - corner) < 0.001 } }
                        check("gesture \(index): the walk visits every corner of the pulse centred at \(String(format: "%.3f", pulse.center))", visited)
                        // Visiting is not enough: a corner that lies INSIDE one straight run
                        // is skipped over, and the tent is cut there. (0.5 then 0.25 then 0.75
                        // visits 0.25 and 0.5 and still draws the wrong thing.) The one run
                        // allowed over a corner is the return to rest, which ends at 0: the
                        // part is then simply dark while it goes, as the camera's ring is
                        // during the last fade, and every flash of it came on the way up.
                        let skipped = corners.filter { corner in
                            runs.contains { run in
                                run.to != 0 && corner > min(run.from, run.to) + 0.001 && corner < max(run.from, run.to) - 0.001
                            }
                        }
                        check("gesture \(index): no corner of the pulse at \(String(format: "%.3f", pulse.center)) is inside a single run", skipped.isEmpty)
                    } else {
                        var shifted = HelmetState.rest
                        shifted.gestures[c] = seen.max() ?? 0
                        let a = spec.motion(of: part, in: .rest), b = spec.motion(of: part, in: shifted)
                        let moved = a.opacity != b.opacity || a.scale != b.scale || a.rotation != b.rotation || a.dx != b.dx || a.dy != b.dy
                        check("gesture \(index): a part on its channel is moved at the top of it", moved)
                    }
                }
            }
            let distinct = Set(gestures.map { $0.map { "\($0.duration)-\($0.curve)-\($0.channel)-\($0.level ?? -9)" }.joined(separator: ",") })
            check("no two gestures of a helmet are the same", distinct.count == gestures.count)
        }

        // How tall each face is drawn: the eye as it always was, a helmet bigger
        // because it has more in it, and always inside the 32 point hover row.
        check("the eye is drawn as it always was: 16 points at rest, 13 on hover",
              AvatarStyle.classic.restHeight == 16 && AvatarStyle.classic.hoverHeight == 13)
        check("every helmet is drawn larger than the eye, at rest and on hover",
              AvatarStyle.allCases.filter(\.isHelmet).allSatisfy { $0.restHeight > 16 && $0.hoverHeight > 13 })
        check("a helmet fits in the 32 point hover row with room above and below",
              AvatarStyle.allCases.allSatisfy { $0.hoverHeight <= 24 })

        // The original eye has no gesture and costs nothing extra.
        print()
        print("── the original eye ──")
        check("no gesture", HelmetSignature.gestures(for: .classic).isEmpty)
        check("so no cost", HelmetSignature.cost(for: .classic, gesture: 0) == (0, 0))

        let arguments = CommandLine.arguments
        if arguments.count >= 3, arguments[1] == "svg" {
            print()
            print("── svg ──")
            // `svg <dir> [height in points]`: the height decides which details are left in.
            writeSVGs(into: arguments[2], height: arguments.count >= 4 ? CGFloat(Double(arguments[3]) ?? 224) : HelmetSpec.designHeight)
        }

        print()
        if failures == 0 {
            print("RESULT: PASS — five helmets, each with a gesture that is cheap and puts everything back")
        } else {
            print("RESULT: FAIL — \(failures) case(s) wrong")
            exit(1)
        }
    }

    // MARK: - geometry helpers

    static func pointsOf(_ path: HPath) -> [CGPoint] {
        path.flatMap { seg -> [CGPoint] in
            switch seg {
            case .move(let p), .line(let p): return [p]
            case .curve(let to, let c1, let c2): return [to, c1, c2]
            case .close: return []
            }
        }
    }

    static func endpoints(_ path: HPath) -> [CGPoint] {
        path.compactMap { seg -> CGPoint? in
            switch seg {
            case .move(let p), .line(let p): return p
            case .curve(let to, _, _): return to
            case .close: return nil
            }
        }
    }

    /// The bounds of a path by its anchor points. Control points are left out
    /// on purpose: they are not on the curve, and a window's silhouette is its
    /// anchors.
    static func bounds(_ path: HPath) -> CGRect {
        let points = endpoints(path)
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - svg

    static func hex(_ c: HColor) -> String {
        String(format: "#%02X%02X%02X", Int((c.red * 255).rounded()), Int((c.green * 255).rounded()), Int((c.blue * 255).rounded()))
    }

    static func d(_ path: HPath) -> String {
        path.map { seg -> String in
            switch seg {
            case .move(let p): return String(format: "M%.2f %.2f", p.x, p.y)
            case .line(let p): return String(format: "L%.2f %.2f", p.x, p.y)
            case .curve(let to, let c1, let c2): return String(format: "C%.2f %.2f %.2f %.2f %.2f %.2f", c1.x, c1.y, c2.x, c2.y, to.x, to.y)
            case .close: return "Z"
            }
        }.joined(separator: " ")
    }

    static func svg(_ draw: HDraw) -> String {
        var attributes = ["d=\"\(d(draw.path))\""]
        if let fill = draw.fill {
            attributes.append("fill=\"\(hex(fill))\" fill-opacity=\"\(fill.alpha)\"")
            if draw.evenOdd { attributes.append("fill-rule=\"evenodd\"") }
        } else {
            attributes.append("fill=\"none\"")
        }
        if let stroke = draw.stroke {
            attributes.append("stroke=\"\(hex(stroke))\" stroke-opacity=\"\(stroke.alpha)\" stroke-width=\"\(draw.strokeWidth)\" stroke-linecap=\"round\" stroke-linejoin=\"round\"")
        }
        let element = "<path \(attributes.joined(separator: " "))/>"
        return draw.clipToShell ? "<g clip-path=\"url(#shell)\">\(element)</g>" : element
    }

    static func svg(_ draws: [HDraw]) -> String { draws.map { svg($0) }.joined(separator: "\n") }

    /// `height` is how tall the helmet is drawn, in points, which decides what the
    /// legibility rules leave in (see `HelmetSpec.draws(for:pointsPerUnit:)`).
    static func render(_ spec: HelmetSpec, _ s: HelmetState, height: CGFloat = HelmetSpec.designHeight) -> String {
        let ppu = height / HelmetSpec.designHeight
        var out: [String] = []
        out.append("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"-156 -112 312 224\" width=\"624\" height=\"448\">")
        out.append("<defs><clipPath id=\"shell\"><path d=\"\(d(HelmetSpec.shell))\"/></clipPath><clipPath id=\"window\"><path d=\"\(d(spec.window.path))\"/></clipPath></defs>")
        out.append("<rect x=\"-156\" y=\"-112\" width=\"312\" height=\"224\" fill=\"#000\"/>")
        out.append(svg(spec.draws(for: .below, pointsPerUnit: ppu)))
        out.append("<g clip-path=\"url(#window)\">")
        out.append(svg(spec.draws(for: .glass)))
        for rect in spec.eyeRects(s) {
            let r = spec.eyeCornerRadius(for: rect)
            out.append("<rect x=\"\(rect.minX)\" y=\"\(rect.minY)\" width=\"\(rect.width)\" height=\"\(rect.height)\" rx=\"\(r)\" fill=\"\(hex(spec.eyes.dim))\"/>")
            out.append("<rect x=\"\(rect.minX)\" y=\"\(rect.minY)\" width=\"\(rect.width)\" height=\"\(rect.height)\" rx=\"\(r)\" fill=\"\(hex(spec.eyes.bright))\" fill-opacity=\"\(s.led)\"/>")
        }
        out.append("<g transform=\"translate(\(-s.gazeX * 5) \(-s.gazeY * 3))\">\(svg(spec.draws(for: .highlights, pointsPerUnit: ppu)))</g>")
        out.append("<g transform=\"translate(0 \(spec.plateOffsetY(s)))\">\(svg(spec.draws(for: .plate)))")
        if let flash = spec.edgeFlashDraw {
            var faded = flash
            faded.fill = faded.fill.map { HColor($0.hex, $0.alpha * Double(s.gesture(spec.plate.flashGesture))) }
            out.append(svg(faded))
        }
        out.append("</g>")
        for (index, part) in spec.dynamics.enumerated() where part.insideWindow {
            out.append(dynamic(spec, part, index, s))
        }
        out.append("</g>")
        out.append(svg(spec.draws(for: .rim)))
        out.append(svg(spec.draws(for: .above, pointsPerUnit: ppu)))
        out.append(svg(spec.draws(for: .edge, pointsPerUnit: ppu)))
        for (index, part) in spec.dynamics.enumerated() where !part.insideWindow {
            out.append(dynamic(spec, part, index, s))
        }
        out.append("</svg>")
        return out.joined(separator: "\n")
    }

    static func dynamic(_ spec: HelmetSpec, _ part: HDynamic, _ index: Int, _ s: HelmetState) -> String {
        let m = spec.motion(of: part, in: s)
        let transform = "translate(\(m.dx) \(m.dy)) translate(\(part.pivot.x) \(part.pivot.y)) rotate(\(m.rotation)) scale(\(m.scale)) translate(\(-part.pivot.x) \(-part.pivot.y))"
        return "<g opacity=\"\(m.opacity)\" transform=\"\(transform)\">\(svg(spec.draws(for: .dynamic(index))))</g>"
    }

    static func writeSVGs(into directory: String, height: CGFloat = HelmetSpec.designHeight) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let poses: [(String, HelmetState)] = [
            ("rest", .rest),
            ("blink", HelmetState(lid: 1)),
            ("left", HelmetState(gazeX: -0.9)),
            ("wide", HelmetState(dilation: 1.35, led: 1)),
            ("signature", HelmetState(led: 0.3, gestures: [1, 0, 0])),
        ]
        for style in AvatarStyle.allCases {
            guard let spec = style.helmet else { continue }
            for (name, state) in poses {
                let path = "\(directory)/\(style.rawValue)-\(name).svg"
                do {
                    try render(spec, state, height: height).write(toFile: path, atomically: true, encoding: .utf8)
                } catch {
                    print("  FAIL  could not write \(path): \(error)")
                    failures += 1
                }
            }
            print("  wrote \(style.rawValue) × \(poses.count)")
        }
    }
}
