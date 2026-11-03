// Do the helmets hold together, and are their gestures cheap enough for battery?
//
// Everything a helmet is — its outlines, colours, how the visor and the LED eyes
// move, and the little gesture each one makes on its own — is plain data in
// Foundation-only files, so it can be checked without a screen, and drawn to SVG
// to be looked at. `HelmetView` is only the interpreter of this data.
//
//   swiftc -swift-version 6 -o /tmp/helmet spike/HelmetVerify.swift \
//       Sources/Runway/UI/AvatarStyle.swift Sources/Runway/UI/HelmetGeometry.swift \
//       Sources/Runway/UI/HelmetSpec.swift Sources/Runway/UI/HelmetSignature.swift \
//       Sources/Runway/UI/HelmetData*.swift spike/HelmetLive.swift spike/HelmetFrames.swift \
//       spike/HelmetAudit.swift \
//       && /tmp/helmet
//
// Add `svg <directory> [height in points]` to also write each helmet in five poses
// as SVG, and `frames <directory> [frames per gesture]` to write every gesture of
// every helmet as a strip of SVG frames, drawn the way SwiftUI would animate it.

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
        check("the five originals are there, and every other helmet has an entry in the collection",
              helmets.count == 5 + HelmetCollection.entries.count
                  && helmets.dropFirst(5).allSatisfy { HelmetCollection.entries[$0] != nil })
        check("no entry in the collection is for a style that does not exist (or is the eye)",
              HelmetCollection.entries.keys.allSatisfy { $0.isHelmet })
        check("every style has a name and a tooltip", AvatarStyle.allCases.allSatisfy { !$0.title.isEmpty && !$0.summary.isEmpty })
        check("raw values are stable (they are stored in UserDefaults)",
              AvatarStyle.allCases.map(\.rawValue) == expectedRawValues)
        check("every style is on a shelf of the picker, and every shelf of the picker has a style",
              AvatarStyle.allCases.allSatisfy { $0.family.styles.contains($0) }
                  && AvatarFamily.allCases.reduce(0) { $0 + $1.styles.count } == AvatarStyle.allCases.count)

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
            let hull = bounds(spec.silhouette)
            check("the silhouette fits the 312 x 224 box", HelmetVerify.box.contains(hull) && hull.width >= 150 && hull.height >= 150)
            check("the window sits inside the silhouette", !spec.silhouette.isEmpty && hull.contains(window))
            check("the silhouette is one closed outline of at least three corners",
                  spec.silhouette.filter { if case .move = $0 { return true } else { return false } }.count == 1
                      && spec.silhouette.last == .close && pointsOf(spec.silhouette).count >= 6)
            check("the middle of the window is inside the silhouette",
                  inside(spec.silhouette, CGPoint(x: window.midX, y: window.midY)))
            if style.isHelmet, HelmetCollection.entries[style] != nil {
                let own = overlap(mass(spec), raster(shell))
                check("it is not the notch: its shape is its own (\(String(format: "%.2f", own)) of the notch)", own <= 0.9)
                let cells = raster(spec.window.path).filter { $0 }.count
                check("the window is at least 60 cells of the 44 x 32 grid the mark is drawn on (\(cells))", cells >= 60)
                check("the LEDs are at least 3:1 against the glass, so the eyes read",
                      (luminanceOf(spec.eyes.dim) + 0.05) / (luminanceOf(spec.window.glass) + 0.05) >= 3)
                check("the edge light is a different colour from every other helmet's",
                      helmets.filter { $0 != style }.allSatisfy { other in other.helmet.map { $0.edge.hex != spec.edge.hex } ?? true })
            }
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
            // The box above is the window's bounding box. For a window that is not a rectangle (a cross, a T, two
            // lenses) the eyes must stay in its real shape, at the range the animator and the gestures use: gaze to
            // either side and up or down by up to 0.8, dilation from squint to the widest `widen` makes.
            var shaped = true
            for gx: CGFloat in stride(from: -1, through: 1, by: 0.25).map({ CGFloat($0) }) {
                for gy: CGFloat in stride(from: -0.8, through: 0.8, by: 0.2).map({ CGFloat($0) }) {
                    for dilation: CGFloat in [0.6, 0.8, 1, 1.2] {
                        var s = HelmetState.rest
                        s.gazeX = gx; s.gazeY = gy; s.dilation = dilation
                        for rect in spec.eyeRects(s) {
                            let r = spec.eyeCornerRadius(for: rect) * 0.29
                            let points = [CGPoint(x: rect.minX + r, y: rect.minY + r), CGPoint(x: rect.maxX - r, y: rect.minY + r),
                                          CGPoint(x: rect.minX + r, y: rect.maxY - r), CGPoint(x: rect.maxX - r, y: rect.maxY - r),
                                          CGPoint(x: rect.midX, y: rect.midY)]
                            if !points.allSatisfy({ HelmetVerify.inside(spec.window.path, $0) }) { shaped = false }
                        }
                    }
                }
            }
            check("the LEDs stay inside the window's real shape at the animator's range of gaze and dilation", shaped)
            check("neither the silhouette nor the window crosses itself (the shadow is an even-odd fill of the outline)",
                  selfCrossings(spec.silhouette) == 0 && selfCrossings(spec.window.path) == 0)
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
            let ratio = (luminanceOf(spec.edge) + 0.05) / 0.05
            print("  \(style.rawValue): edge light is \(String(format: "%.1f", ratio)):1 against black, shell \(String(format: "%.2f", (luminanceOf(HColor(spec.below.first?.fill?.hex ?? 0x2B2D32)) + 0.05) / 0.05)):1 for comparison")
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
        // The band under the cutout is drawn over the user's title bar and tabs.
        // It was 22 points tall with the eye, and a helmet must not make it taller.
        check("the band under the cutout is 22 points whatever the face (row + air)",
              AvatarStyle.allCases.allSatisfy { $0.restRowHeight + $0.restBottomPadding == 22 })
        check("the mark fits its row, so it cannot spill into the band's edge",
              AvatarStyle.allCases.allSatisfy { $0.restHeight <= $0.restRowHeight })
        check("every helmet is drawn larger than the eye, at rest and on hover",
              AvatarStyle.allCases.filter(\.isHelmet).allSatisfy { $0.restHeight > 16 && $0.hoverHeight > 13 })
        check("a helmet fits in the 32 point hover row with room above and below",
              AvatarStyle.allCases.allSatisfy { $0.hoverHeight <= 24 })

        collectionChecks(helmets)
        LiveDraw.run(helmets)
        HelmetAudit.run(helmets)

        // The original eye has no gesture and costs nothing extra.
        print()
        print("── the original eye ──")
        check("no gesture", HelmetSignature.gestures(for: .classic).isEmpty)
        check("so no cost", HelmetSignature.cost(for: .classic, gesture: 0) == (0, 0))

        let arguments = CommandLine.arguments
        if arguments.count >= 3, arguments[1] == "frames" {
            print()
            print("── frames ──")
            writeFrames(into: arguments[2], count: arguments.count >= 4 ? Int(arguments[3]) ?? 9 : 9)
        }
        if arguments.count >= 3, arguments[1] == "svg" {
            print()
            print("── svg ──")
            // `svg <dir> [height in points]`: the height decides which details are left in.
            writeSVGs(into: arguments[2], height: arguments.count >= 4 ? CGFloat(Double(arguments[3]) ?? 224) : HelmetSpec.designHeight)
        }

        print()
        if failures == 0 {
            print("RESULT: PASS — \(helmets.count) helmets, each with gestures that are cheap, put everything back, and come out of the same random draw as every other beat")
        } else {
            print("RESULT: FAIL — \(failures) case(s) wrong")
            exit(1)
        }
    }

    // MARK: - what the collection has to be

    static let box = CGRect(x: -156, y: -112, width: 312, height: 224)

    /// Stored in UserDefaults, so these never change; a new face is added at the end.
    static let expectedRawValues = [
        "classic", "apollo", "orlan", "stealth", "papaya", "endurance",
        "fire", "diver", "kabuto", "greathelm",
        "gridiron", "moto", "halo", "aviator",
        "fighter", "miner", "welder", "corinthian",
        "kendo", "murmillo", "bascinet", "gjermundbu",
        "ski", "forestry", "custodian", "fencing",
        "heli", "jockey",
    ]

    static func luminanceOf(_ c: HColor) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.red * c.alpha) + 0.7152 * lin(c.green * c.alpha) + 0.0722 * lin(c.blue * c.alpha)
    }

    /// An outline as straight segments, curves cut into 12.
    static func flatten(_ path: HPath) -> [[CGPoint]] {
        var polygons: [[CGPoint]] = []
        var current: [CGPoint] = []
        var last = CGPoint.zero
        for seg in path {
            switch seg {
            case .move(let p):
                if current.count > 2 { polygons.append(current) }
                current = [p]; last = p
            case .line(let p):
                current.append(p); last = p
            case .curve(let to, let c1, let c2):
                for i in 1...12 {
                    let t = CGFloat(i) / 12, u = 1 - t
                    let x = u * u * u * last.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * to.x
                    let y = u * u * u * last.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * to.y
                    current.append(CGPoint(x: x, y: y))
                }
                last = to
            case .close:
                break
            }
        }
        if current.count > 2 { polygons.append(current) }
        return polygons
    }

    /// How many times an outline crosses itself: edges that are not neighbours and that cut each other.
    static func selfCrossings(_ path: HPath) -> Int {
        func side(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
        var crossings = 0
        for polygon in flatten(path) {
            let count = polygon.count
            for i in 0..<count {
                guard i + 2 < count else { continue }
                let a = polygon[i], b = polygon[(i + 1) % count]
                for j in (i + 2)..<count where !(i == 0 && j == count - 1) {
                    let c = polygon[j], d = polygon[(j + 1) % count]
                    if side(a, b, c) * side(a, b, d) < 0 && side(c, d, a) * side(c, d, b) < 0 { crossings += 1 }
                }
            }
        }
        return crossings
    }

    /// Non-zero winding, which is how the notch is clipped.
    static func inside(_ path: HPath, _ p: CGPoint) -> Bool {
        var winding = 0
        for polygon in flatten(path) {
            for i in 0..<polygon.count {
                let a = polygon[i], b = polygon[(i + 1) % polygon.count]
                if a.y <= p.y {
                    if b.y > p.y && (b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y) > 0 { winding += 1 }
                } else if b.y <= p.y && (b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y) < 0 {
                    winding -= 1
                }
            }
        }
        return winding != 0
    }

    /// The outline on the 44 x 32 grid the mark is drawn on at 22 x 16 points and
    /// 2x: one bool per pixel, sampled at its centre.
    static func raster(_ path: HPath, columns: Int = 44, rows: Int = 32) -> [Bool] {
        var cells: [Bool] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let x = -156 + (CGFloat(column) + 0.5) * 312 / CGFloat(columns)
                let y = -112 + (CGFloat(row) + 0.5) * 224 / CGFloat(rows)
                cells.append(inside(path, CGPoint(x: x, y: y)))
            }
        }
        return cells
    }

    /// What the eye sees of a helmet at rest on that grid: the silhouette, and whatever stands
    /// outside it or in front of it that is drawn at rest (the halo's arch, a peak, ear flaps, a
    /// facemask), strokes at their width. Two helmets with the same dome and different things
    /// on it are different shapes, and the silhouette alone would call them the same.
    static func mass(_ spec: HelmetSpec, columns: Int = 44, rows: Int = 32) -> [Bool] {
        var cells = raster(spec.silhouette, columns: columns, rows: rows)
        var draws = spec.above
        for (index, part) in spec.dynamics.enumerated() where spec.motion(of: part, in: .rest).opacity > 0.5 {
            draws += spec.draws(for: .dynamic(index))
        }
        for draw in draws {
            let polygons = flatten(draw.path)
            for row in 0..<rows {
                for column in 0..<columns where !cells[row * columns + column] {
                    let p = CGPoint(x: -156 + (CGFloat(column) + 0.5) * 312 / CGFloat(columns), y: -112 + (CGFloat(row) + 0.5) * 224 / CGFloat(rows))
                    var hit = false
                    if draw.fill != nil, inside(draw.path, p) { hit = true }
                    if !hit, draw.stroke != nil {
                        let reach = max(draw.strokeWidth, 6) / 2
                        outer: for polygon in polygons {
                            for i in 0..<polygon.count {
                                let a = polygon[i], b = polygon[(i + 1) % polygon.count]
                                let dx = b.x - a.x, dy = b.y - a.y
                                let length2 = dx * dx + dy * dy
                                let t = length2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length2))
                                let ex = a.x + t * dx - p.x, ey = a.y + t * dy - p.y
                                if ex * ex + ey * ey <= reach * reach { hit = true; break outer }
                            }
                        }
                    }
                    if hit { cells[row * columns + column] = true }
                }
            }
        }
        return cells
    }

    /// Intersection over union of two grids.
    static func overlap(_ x: [Bool], _ y: [Bool]) -> Double {
        var both = 0, either = 0
        for i in x.indices {
            if x[i] && y[i] { both += 1 }
            if x[i] || y[i] { either += 1 }
        }
        return either == 0 ? 1 : Double(both) / Double(either)
    }

    static func overlap(_ a: HPath, _ b: HPath) -> Double { overlap(raster(a), raster(b)) }

    /// What has to hold of the collection as a whole, and not of one helmet.
    static func collectionChecks(_ helmets: [AvatarStyle]) {
        print()
        print("── the collection ──")
        let own = helmets.filter { HelmetCollection.entries[$0] != nil }
        var worst: (Double, String) = (0, "")
        var pairs = 0
        let masses = own.map { $0.helmet.map { mass($0) } ?? [] }
        for i in own.indices {
            for j in own.indices where j > i {
                let o = overlap(masses[i], masses[j])
                pairs += 1
                if o > worst.0 { worst = (o, "\(own[i].rawValue) / \(own[j].rawValue)") }
            }
        }
        print("  most alike shapes (silhouette plus what stands out of it) at 44 x 32: \(worst.1), \(String(format: "%.2f", worst.0)) overlap (\(pairs) pairs)")
        check("no two of the new helmets share a silhouette: every pair overlaps by at most 0.90 on the 44 x 32 grid", worst.0 <= 0.90)

        // A gesture is unique to its helmet when no moving part of it is drawn by another.
        var seen: [String: AvatarStyle] = [:]
        var clash: [String] = []
        for style in helmets {
            guard let spec = style.helmet else { continue }
            for part in spec.dynamics where part.channel != .led {
                let key = part.draws.map { "\(d($0.path))|\($0.fill?.hex ?? 0)|\($0.stroke?.hex ?? 0)" }.joined(separator: ";")
                if let other = seen[key], other != style { clash.append("\(style.rawValue)=\(other.rawValue)") }
                seen[key] = style
            }
        }
        check("no moving part of a gesture is drawn identically by two helmets \(clash.prefix(3))", clash.isEmpty)
        let channels = own.allSatisfy { HelmetSignature.gestures(for: $0).count == HelmetState.gestureSlots }
        check("every new helmet has all \(HelmetState.gestureSlots) gestures, one per channel", channels)
        // Every moving part is a view and a layer the compositor keeps, drawn or not, so the count is a cost of its own.
        let partCounts = helmets.map { $0.helmet?.dynamics.count ?? 0 }
        print("  moving parts per helmet: \(String(format: "%.1f", Double(partCounts.reduce(0, +)) / Double(max(partCounts.count, 1)))) on average, \(partCounts.max() ?? 0) at most")
        check("no helmet has more than 24 moving parts", partCounts.allSatisfy { $0 <= 24 })
        let battery = own.allSatisfy { style in
            HelmetSignature.gestures(for: style).indices.filter { index in
                let c = HelmetSignature.cost(for: style, gesture: index)
                return c.seconds <= 0.5 && c.moves <= 6
            }.count >= 2
        }
        check("at least two gestures of every new helmet are frugal, so they are in the draw on battery", battery)
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
        render(spec, HelmetPose(spec, s), height: height)
    }

    /// A helmet at one instant, from what each part is doing at it. The state-to-pose
    /// step is `HelmetPose`, so a frame half way through a move can be drawn too.
    static func render(_ spec: HelmetSpec, _ pose: HelmetPose, height: CGFloat = HelmetSpec.designHeight) -> String {
        let ppu = height / HelmetSpec.designHeight
        var out: [String] = []
        out.append("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"-156 -112 312 224\" width=\"624\" height=\"448\">")
        out.append("<defs><clipPath id=\"shell\"><path d=\"\(d(spec.silhouette))\"/></clipPath><clipPath id=\"window\"><path d=\"\(d(spec.window.path))\"/></clipPath></defs>")
        out.append("<rect x=\"-156\" y=\"-112\" width=\"312\" height=\"224\" fill=\"#000\"/>")
        out.append(svg(spec.draws(for: .below, pointsPerUnit: ppu)))
        out.append("<g clip-path=\"url(#window)\">")
        out.append(svg(spec.draws(for: .glass)))
        for rect in pose.eyes {
            let r = spec.eyeCornerRadius(for: rect)
            out.append("<rect x=\"\(rect.minX)\" y=\"\(rect.minY)\" width=\"\(rect.width)\" height=\"\(rect.height)\" rx=\"\(r)\" fill=\"\(hex(spec.eyes.dim))\"/>")
            out.append("<rect x=\"\(rect.minX)\" y=\"\(rect.minY)\" width=\"\(rect.width)\" height=\"\(rect.height)\" rx=\"\(r)\" fill=\"\(hex(spec.eyes.bright))\" fill-opacity=\"\(pose.led)\"/>")
        }
        out.append("<g transform=\"translate(\(-pose.gazeX * 5) \(-pose.gazeY * 3))\">\(svg(spec.draws(for: .highlights, pointsPerUnit: ppu)))</g>")
        out.append("<g transform=\"translate(0 \(pose.plateY))\">\(svg(spec.draws(for: .plate)))")
        if let flash = spec.edgeFlashDraw {
            var faded = flash
            faded.fill = faded.fill.map { HColor($0.hex, $0.alpha * Double(pose.flash)) }
            out.append(svg(faded))
        }
        out.append("</g>")
        for (index, part) in spec.dynamics.enumerated() where part.insideWindow {
            out.append(dynamic(spec, part, index, pose.parts[index]))
        }
        out.append("</g>")
        out.append(svg(spec.draws(for: .rim)))
        out.append(svg(spec.draws(for: .above, pointsPerUnit: ppu)))
        out.append(svg(spec.draws(for: .edge, pointsPerUnit: ppu)))
        for (index, part) in spec.dynamics.enumerated() where !part.insideWindow {
            out.append(dynamic(spec, part, index, pose.parts[index]))
        }
        out.append("</svg>")
        return out.joined(separator: "\n")
    }

    static func dynamic(_ spec: HelmetSpec, _ part: HDynamic, _ index: Int, _ m: HelmetPose.Part) -> String {
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
            ("signature", HelmetState(led: 0.3, gestures: [1] + [CGFloat](repeating: 0, count: HelmetState.gestureSlots - 1))),
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
