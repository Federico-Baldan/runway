// How the gestures come out when the app runs: at random, from the same weighted
// draw as every other beat, on whatever the Mac can afford.
//
// `IdleMarkAnimator.pool(power:)` and `nextBeat(power:)` are SwiftUI, IOKit and
// ProcessInfo, so they cannot be compiled here. What can be run is a model of
// them, and what keeps the model honest is that it READS the real table out of
// IdleMark.swift (the weights, the costs, the gesture weight, the battery and
// Low Power rules) and fails if any of them has moved. A change to the animator
// that this model does not know about is a failing spike, not a silent lie.
//
// Foundation only, like `HelmetVerify`, whose `check` it reports through.

// CGRect, CGPoint and CGSize come with their members only from CoreGraphics on
// macOS, which has no such module on Linux, where Foundation has them all.
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

enum LiveDraw {
    enum Power: String, CaseIterable { case wall, battery, lowPower }

    struct Beat {
        let name: String
        let weight: Int
        let moves: Int
        let seconds: Double
        var isFrugal: Bool { seconds <= 0.5 && moves <= 6 }
        var isLidOnly: Bool { LiveDraw.lidOnly.contains(name) }
        let gesture: Int?

        func allowed(on power: Power) -> Bool {
            switch power {
            case .wall: return true
            case .battery: return isFrugal
            case .lowPower: return isLidOnly
            }
        }
    }

    /// The non-gesture beats of a mark that is not yet tired, in the order the
    /// animator lists them. `lookAround` with three or four fixations is a coin
    /// flip in the animator; both outcomes cost more than half a second, so it
    /// is modelled by the dearer one.
    static let waking: [(name: String, weight: Int, moves: Int, seconds: Double)] = [
        ("blink", 20, 2, 0.17), ("doubleBlink", 7, 4, 0.47), ("lookAround", 10, 5, 0.49),
        ("lookAround", 4, 7, 0.75), ("slowBlink", 6, 2, 0.45), ("squint", 5, 2, 0.29),
        ("flutter", 3, 6, 0.36), ("drowse", 4, 4, 1.16), ("doubleTake", 6, 6, 0.40),
        ("follow", 6, 4, 1.44), ("roll", 3, 10, 1.51), ("nod", 4, 5, 0.24), ("shake", 3, 5, 0.40),
        ("focus", 5, 4, 0.48), ("drift", 5, 4, 2.07), ("peek", 5, 5, 0.43), ("scan", 4, 8, 0.53),
        ("widen", 5, 2, 0.42), ("recoil", 2, 4, 0.22), ("linger", 6, 4, 0.29), ("pulse", 5, 4, 0.46),
        ("hiccup", 3, 4, 0.34), ("sneeze", 2, 6, 1.07), ("sideEye", 4, 5, 0.64),
    ]

    static let lidOnly: Set<String> = ["blink", "doubleBlink", "slowBlink", "squint", "flutter", "widen", "pulse", "heavyBlink"]

    /// What each gesture of a helmet is worth in the draw: `weight: 4`, read from the source below.
    static let gestureWeight = 4

    static func pool(for style: AvatarStyle, on power: Power) -> [Beat] {
        var all = waking.map { Beat(name: $0.name, weight: $0.weight, moves: $0.moves, seconds: $0.seconds, gesture: nil) }
        for index in HelmetSignature.gestures(for: style).indices {
            let cost = HelmetSignature.cost(for: style, gesture: index)
            all.append(Beat(name: "gesture \(index)", weight: gestureWeight, moves: cost.moves, seconds: cost.seconds, gesture: index))
        }
        return all.filter { $0.weight > 0 && $0.allowed(on: power) }
    }

    /// `Int.random(in: 0..<total)` and the walk down the entries, exactly as `nextBeat` does it,
    /// with a generator that can be seeded.
    struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    static func draw(_ pool: [Beat], _ rng: inout SplitMix64) -> Beat? {
        let total = pool.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }
        var pick = rng.below(total)
        for entry in pool {
            pick -= entry.weight
            if pick < 0 { return entry }
        }
        return pool.last
    }

    static func meanSeconds(_ pool: [Beat]) -> Double {
        let total = Double(pool.reduce(0) { $0 + $1.weight })
        guard total > 0 else { return 0 }
        return pool.reduce(0.0) { $0 + Double($1.weight) * $1.seconds } / total
    }

    static func gestureShare(_ pool: [Beat]) -> Double {
        let total = Double(pool.reduce(0) { $0 + $1.weight })
        guard total > 0 else { return 0 }
        return Double(pool.filter { $0.gesture != nil }.reduce(0) { $0 + $1.weight }) / total
    }

    // MARK: - the model has to be the animator

    /// Reads the table out of IdleMark.swift and compares it with `waking` and the rules above.
    static func sourceMatchesModel() {
        let path = "Sources/Runway/UI/IdleMark.swift"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("  WARN  \(path) not found from here (run the spike from the repository root): the model is not checked against the animator")
            return
        }
        let lines = text.components(separatedBy: "\n")
        // The weights.
        var weights: [(String, Int)] = []
        if let start = lines.firstIndex(where: { $0.contains("var all: [(weight: Int, beat: Beat)] = [") }) {
            let weightPattern = try! NSRegularExpression(pattern: "\\(\\s*(\\d+),\\s*\\.(\\w+)")
            for line in lines[(start + 1)...] {
                if line.trimmingCharacters(in: .whitespaces) == "]" { break }
                let range = NSRange(line.startIndex..., in: line)
                if let m = weightPattern.firstMatch(in: line, range: range),
                   let w = Range(m.range(at: 1), in: line), let n = Range(m.range(at: 2), in: line) {
                    weights.append((String(line[n]), Int(line[w]) ?? -1))
                }
            }
        }
        let model = waking.map { ($0.name, $0.weight) }
        HelmetVerify.check("the model's weights are the animator's, name by name and in order (\(weights.count) beats in IdleMark.swift)",
                           weights.count == model.count && zip(weights, model).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 })
        // The costs of the beats that have a fixed one.
        let costPattern = try! NSRegularExpression(pattern: "case \\.(\\w+): return \\((\\d+), ([0-9.]+)\\)")
        var costs: [String: (Int, Double)] = [:]
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            if let m = costPattern.firstMatch(in: line, range: range),
               let n = Range(m.range(at: 1), in: line), let a = Range(m.range(at: 2), in: line), let b = Range(m.range(at: 3), in: line) {
                costs[String(line[n])] = (Int(line[a]) ?? -1, Double(line[b]) ?? -1)
            }
        }
        let fixed = waking.filter { $0.name != "lookAround" }
        HelmetVerify.check("the model's costs are the animator's, for every beat that has a fixed one",
                           fixed.allSatisfy { entry in costs[entry.name].map { $0.0 == entry.moves && abs($0.1 - entry.seconds) < 0.0001 } ?? false })
        HelmetVerify.check("lookAround costs (fixations + 3) moves and fixations x 0.13 + 0.23 seconds",
                           text.contains("return (fixations + 3, Double(fixations) * 0.13 + 0.23)"))
        // The rules of the three power sources.
        HelmetVerify.check("a gesture is in the draw at weight 4, each, as a signature beat",
                           text.contains("all.append((weight: 4, beat: .signature(avatar, index)))")
                               && text.contains("for index in HelmetSignature.gestures(for: avatar).indices"))
        HelmetVerify.check("frugal is half a second and six moves, and battery allows only the frugal",
                           text.contains("var isFrugal: Bool { cost.seconds <= 0.5 && cost.moves <= 6 }")
                               && text.contains("case .battery: return beat.isFrugal"))
        HelmetVerify.check("Low Power allows only the lid-only beats, which are the ones modelled",
                           text.contains("case .lowPower: return beat.isLidOnly")
                               && text.contains("case .blink, .doubleBlink, .slowBlink, .squint, .flutter, .widen,")
                               && text.contains(".pulse, .heavyBlink:"))
        HelmetVerify.check("a gesture is a `.signature` beat and so not lid-only (the default branch of isLidOnly)",
                           text.contains("default: return false"))
        HelmetVerify.check("the draw is one Int.random over the summed weights, walked in order, with no repeat avoidance",
                           text.contains("var draw = Int.random(in: 0..<total)") && !text.contains("lastBeat") && !text.contains("previousBeat"))
    }

    // MARK: - the table

    static func run(_ helmets: [AvatarStyle]) {
        print()
        print("── the live draw: gestures at random, on each power source ──")
        sourceMatchesModel()

        let draws = 40_000
        var rng = SplitMix64(state: 0x5EED_2026_1102)
        var worstDeviation = [Power: Double]()
        var everyoneAppears = true
        var rows: [String] = []
        let eyeLine = Power.allCases.map { power in String(format: "%.3f", meanSeconds(pool(for: .classic, on: power))) }
        for style in helmets {
            var cells: [String] = []
            for power in Power.allCases {
                let p = pool(for: style, on: power)
                let total = Double(p.reduce(0) { $0 + $1.weight })
                var counts = [String: Int]()
                for _ in 0..<draws { if let beat = draw(p, &rng) { counts[beat.name, default: 0] += 1 } }
                var worst = 0.0
                for beat in p where beat.gesture != nil {
                    let expected = Double(beat.weight) / total
                    let seen = Double(counts[beat.name] ?? 0) / Double(draws)
                    let sigma = (expected * (1 - expected) / Double(draws)).squareRoot()
                    // Five standard deviations: a fair draw stays inside it for every one of ~3000
                    // gestures here, and a draw that skips a gesture or double-counts one does not.
                    worst = max(worst, abs(seen - expected) / max(sigma, 1e-9))
                    if counts[beat.name, default: 0] == 0 { everyoneAppears = false }
                }
                worstDeviation[power] = max(worstDeviation[power] ?? 0, worst)
                let gestures = p.filter { $0.gesture != nil }.count
                cells.append(String(format: "%d of %d in the draw, %4.1f%% of beats, mean %.3f s", gestures, HelmetState.gestureSlots, gestureShare(p) * 100, meanSeconds(p)))
            }
            rows.append("  \(style.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) | " + cells.joined(separator: " | "))
        }
        print("  helmet     | wall | battery | Low Power   (gestures in the pool, share of draws that are a gesture, mean animated seconds per beat)")
        for row in rows { print(row) }
        print("  the eye    | mean \(eyeLine[0]) s | mean \(eyeLine[1]) s | mean \(eyeLine[2]) s (no gestures)")
        for power in Power.allCases {
            let worst = worstDeviation[power] ?? 0
            HelmetVerify.check("\(power.rawValue): over \(draws) seeded draws every gesture in the pool comes out within 5 sigma of its share (worst \(String(format: "%.1f", worst)) sigma)",
                               worst <= 5)
        }
        HelmetVerify.check("no gesture is ever starved: every gesture in a pool was drawn at least once", everyoneAppears)
        HelmetVerify.check("in Low Power no gesture is in the draw for any helmet (no lid-only gesture exists)",
                           helmets.allSatisfy { style in pool(for: style, on: .lowPower).allSatisfy { $0.gesture == nil } })
        HelmetVerify.check("on battery a helmet has at least two gestures in the draw (all that are frugal)",
                           helmets.allSatisfy { pool(for: $0, on: .battery).filter { $0.gesture != nil }.count >= 2 })
        HelmetVerify.check("battery shares are never below the wall's by more than the dropped beats explain: a gesture is at least as likely on battery",
                           helmets.allSatisfy { gestureShare(pool(for: $0, on: .battery)) >= gestureShare(pool(for: $0, on: .wall)) - 1e-9 })
        // The pool has no memory: the same beat twice in a row is as likely as chance says.
        let one = pool(for: .apollo, on: .wall)
        var again = 0, previous: String?
        var rng2 = SplitMix64(state: 7)
        for _ in 0..<draws {
            if let beat = draw(one, &rng2) { if previous == beat.name { again += 1 }; previous = beat.name }
        }
        let weights = one.map { Double($0.weight) }
        let total = weights.reduce(0, +)
        let expectedRepeat = weights.reduce(0) { $0 + ($1 / total) * ($1 / total) }
        print("  repeats: the same beat twice in a row happens \(String(format: "%.1f", Double(again) / Double(draws) * 100))% of draws (chance says \(String(format: "%.1f", expectedRepeat * 100))%): the pool has no repeat avoidance")
        HelmetVerify.check("the pool has no repeat avoidance: back-to-back repeats are at chance", abs(Double(again) / Double(draws) - expectedRepeat) < 0.01)
    }
}
