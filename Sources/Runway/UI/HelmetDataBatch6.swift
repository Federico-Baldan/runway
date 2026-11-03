// CGRect, CGPoint and CGSize come with their members only from CoreGraphics on
// macOS, which has no such module on Linux, where Foundation has them all.
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

// Batch 6: a helicopter crew helmet with its boom microphone, and a jockey's cap in
// its silks.

extension HelmetCollection {
    static let batch6: [(AvatarStyle, HelmetEntry)] = [
        (.heli, heliHelmet()),
        (.jockey, jockeyHelmet()),
    ]
}

// MARK: - Helicopter

/// A helicopter crew helmet: the smooth shell with its visor housing, the ear cups of
/// the headset, the boom microphone in front of the mouth. The sun visor is the lid.
private func heliHelmet() -> HelmetEntry {
    let shell = hSym([
        (0, -108, 0), (40, -104, 26), (70, -84, 20), (72, -64, 0), (106, -58, 6), (108, -24, 6), (114, -12, 8), (130, 0, 12), (132, 50, 16),
        (110, 64, 10), (98, 52, 0), (86, 84, 16), (48, 108, 16), (0, 108, 0),
    ])
    let red: UInt32 = 0xE5483E
    let cups = hTogether([hOval(-120, 24, 22, 34), hOval(120, 24, 22, 34)])
    let boom = hCurve([(-116, 34), (-100, 68), (-64, 88), (-32, 82)])
    let mic = hOval(-26, 82, 20, 20)
    let cord: [(CGFloat, CGFloat)] = [(-124, 56), (-112, 92), (-72, 106), (-20, 106)]

    var livery: [HDraw] = []
    livery.append(hFill(hBox(0, -50, 230, 28, 8), 0x1F2227, clip: true))
    livery.append(hLine(hPoly([(-110, -50), (110, -50)], closed: false), red, 7, clip: true))
    livery.append(hLine(hPoly(cord, closed: false), 0x383C44, 7, clip: true))

    var above: [HDraw] = []
    above.append(hFill(cups, 0x23262B))
    above.append(hLine(cups, 0xE8DCC0, 6))

    var dynamics: [HDynamic] = []
    // Gesture 0: the boom swings up from the mouth and back. Drawn at rest.
    dynamics.append(HDynamic(draws: [hLine(boom, 0xA9B0BC, 8), hFill(mic, 0xA9B0BC), hFill(hOval(-26, 82, 8, 8), 0x23262B)],
                             channel: .gesture(0), rotation: HRamp(0, 26), pivot: CGPoint(x: -116, y: 34)))
    // Gesture 2: the headset crackles: the ear cups light.
    dynamics.append(hLamp([hFill(hTogether([hOval(-120, 24, 12, 22), hOval(120, 24, 12, 22)]), 0xFF9C94)], gesture: 2))
    // Gesture 3: a light runs along the cord.
    dynamics += hChase(HShape.spans(hPoly(cord, closed: false)), hex: 0xFFD7B0, width: 7, gesture: 3, clip: true)

    let spec = hHelmet(
        shell: shell, base: 0x5B5039, light: 0x877A58,
        lightPath: hCurve([(-70, -66), (-66, -88), (-44, -104), (-20, -106)]), edge: 0xE8DCC0,
        livery: livery,
        window: hBox(0, -4, 176, 72, 30), top: -40, bottom: 32, width: 176,
        glass: 0x0B0C0D, rim: 0x14120C, rimWidth: 10,
        eyes: (w: 30, h: 34, y: -4, dx: 44, tx: 12, ty: 5, dim: 0xF3EBDC, bright: 0xFFFDF4),
        plate: (fill: 0x3A2E14, edge: red, width: 4, deco: [hFill(hPoly([(-90, -41), (-56, -41), (-78, 41), (-112, 41)]), 0x57461F)]),
        flash: 0xFFB4AC, flashGesture: 1,
        above: above, dynamics: dynamics,
        visorNudge: 0.5, visorGesture: 1
    )
    let gestures: [[SignatureStep]] = [
        // The boom swings up from the mouth and drops back, the eyes following it.
        [
            hs(0.12, hold: 0.1, ch: 0, lv: 1, gx: -0.6, gy: 0.5),
            hs(0.16, .easeInOut, ch: 0, lv: 0, gx: 0, gy: 0),
        ],
        // The sun visor comes down.
        [
            hs(0.12, hold: 0.18, ch: 1, lv: 1, dil: 0.85),
            hs(0.16, .easeIn, ch: 1, lv: 0, dil: 1),
        ],
        // A call comes in: the ear cups flash twice.
        [
            hs(0.06, hold: 0.03, ch: 2, lv: 1, gx: 0.6),
            hs(0.1, hold: 0.04, .easeIn, ch: 2, lv: 0),
            hs(0.06, hold: 0.03, ch: 2, lv: 1),
            hs(0.12, .easeIn, ch: 2, lv: 0, gx: 0, gy: 0),
        ],
        // A light runs along the headset cord.
        hWalk([0.25, 0.5, 0.75, 1], ch: 3, each: 0.1),
    ]
    return HelmetEntry(spec: spec, gestures: gestures, reference: "Helicopter crew helmet: visor housing, sun visor, headset ear cups, boom microphone")
}

// MARK: - Jockey

/// A jockey's helmet in its silks: the dome cut in four colours, the little pom on top,
/// the goggles on their band and the chin strap. The goggle lens is the lid.
private func jockeyHelmet() -> HelmetEntry {
    let shell = hSym([
        (0, -100, 0), (56, -96, 34), (96, -60, 30), (102, -20, 6), (130, -4, 8), (136, 6, 4), (100, 14, 0),
        (96, 52, 18), (70, 96, 18), (30, 110, 12), (0, 110, 0),
    ])
    let purple: UInt32 = 0x5B2C83, gold: UInt32 = 0xC49A2E
    let quarters: [HPath] = [
        hPoly([(-160, -120), (0, -120), (0, -40), (-160, -40)]),
        hPoly([(0, -120), (160, -120), (160, -40), (0, -40)]),
        hPoly([(0, -40), (160, -40), (160, 14), (0, 14)]),
        hPoly([(-160, -40), (0, -40), (0, 14), (-160, 14)]),
    ]
    let buckle = hBox(48, 82, 18, 14, 4)

    var livery: [HDraw] = []
    livery.append(hFill(quarters[0], purple, clip: true))
    livery.append(hFill(quarters[1], gold, clip: true))
    livery.append(hFill(quarters[2], purple, clip: true))
    livery.append(hFill(quarters[3], gold, clip: true))
    livery.append(hLine(hCurve([(-72, 72), (0, 98), (72, 72)]), 0x0B0C0F, 8, clip: true))

    let above: [HDraw] = [hFill(buckle, gold)]

    var dynamics: [HDynamic] = []
    // Gesture 0: the pom on top bobs. Drawn at rest.
    dynamics.append(HDynamic(draws: [hFill(hOval(0, -97, 18, 18), gold), hLine(hOval(0, -97, 18, 18), 0xFFE9A8, 6)],
                             channel: .gesture(0), offsetY: HRamp(0, -6)))
    // Gesture 1: the four quarters of the silks flash in turn, clockwise from the top left.
    let order = [0, 1, 2, 3]
    for (index, quarter) in order.enumerated() {
        dynamics.append(hGlow([hFill(quarters[quarter], 0xFFFFFF, 0.55, clip: true)], gesture: 1,
                              center: CGFloat(index + 1) / 5, width: 0.2))
    }
    // Gesture 3: the buckle of the chin strap catches the light.
    dynamics.append(hLamp([hFill(buckle, 0xFFFFFF)], gesture: 3))

    let spec = hHelmet(
        shell: shell, base: 0x24262B, light: 0x4A4D57,
        lightPath: hCurve([(-98, -20), (-92, -58), (-58, -92), (-24, -96)]), edge: 0xD9C6F2,
        livery: livery,
        window: hBox(0, 24, 170, 56, 24), top: -4, bottom: 52, width: 170,
        rim: gold, rimWidth: 10,
        eyes: (w: 30, h: 30, y: 24, dx: 44, tx: 12, ty: 5, dim: 0xF2EEF6, bright: 0xFFFFFF),
        plate: (fill: 0x2A2336, edge: gold, width: 4, deco: [hFill(hPoly([(-86, -26), (-54, -26), (-74, 26), (-106, 26)]), 0x3C3150)]),
        flash: 0xFFE9A8, flashGesture: 2,
        above: above, dynamics: dynamics,
        visorNudge: 0.5, visorGesture: 2
    )
    let gestures: [[SignatureStep]] = [
        // The pom bobs, twice, and the eyes look up.
        [
            hs(0.07, hold: 0.03, ch: 0, lv: 1, gx: 0, gy: -0.8),
            hs(0.09, hold: 0.03, .easeInOut, ch: 0, lv: 0),
            hs(0.07, hold: 0.03, ch: 0, lv: 1),
            hs(0.1, .easeInOut, ch: 0, lv: 0, gx: 0, gy: 0),
        ],
        // The quarters of the silks flash in turn.
        hWalk([0.2, 0.4, 0.6, 0.8, 1], ch: 1, each: 0.08),
        // The goggles are pulled down over the eyes.
        [
            hs(0.12, hold: 0.18, ch: 2, lv: 1, dil: 0.85),
            hs(0.16, .easeIn, ch: 2, lv: 0, dil: 1),
        ],
        // The buckle catches the light and the eyes look down at it.
        [
            hs(0.07, hold: 0.12, ch: 3, lv: 1, gx: 0.5, gy: 0.8),
            hs(0.14, .easeIn, ch: 3, lv: 0, gx: 0, gy: 0),
        ],
    ]
    return HelmetEntry(spec: spec, gestures: gestures, reference: "Jockey's helmet in silks: quartered cover, pom, goggles, chin strap")
}
