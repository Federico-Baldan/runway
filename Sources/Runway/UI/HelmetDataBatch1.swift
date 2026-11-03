// CGRect, CGPoint and CGSize come with their members only from CoreGraphics on
// macOS, which has no such module on Linux, where Foundation has them all.
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

// Batch 1: a fire helmet, a brass diving helmet, a samurai kabuto and a great
// helm. See `HelmetCollection` and `HelmetDataKit` for how they are made.

extension HelmetCollection {
    static let batch1: [(AvatarStyle, HelmetEntry)] = [
        (.fire, fireHelmet()),
        (.diver, diverHelmet()),
        (.kabuto, kabutoHelmet()),
        (.greathelm, greatHelm()),
    ]
}

// MARK: - Fire

/// A fire helmet seen from the front: the crown with its comb and the red front
/// shield, the wide brim that gives it its shape, a face shield, and the hood.
/// The shield is the lid.
private func fireHelmet() -> HelmetEntry {
    let shell = hSym([
        (0, -112, 0), (58, -110, 34), (98, -92, 26), (104, -56, 8), (106, -36, 0),
        (154, -30, 8), (156, -8, 8), (104, 4, 4),
        (96, 50, 22), (76, 96, 30), (38, 112, 16), (0, 112, 0),
    ])
    let red: UInt32 = 0xD9362B, brass: UInt32 = 0xC9A24A
    let shield = hPoly([(-27, -102), (27, -102), (31, -56), (0, -32), (-31, -56)])
    let trim: [(CGFloat, CGFloat)] = [(-146, -13), (-50, -13), (50, -13), (146, -13)]

    var livery: [HDraw] = []
    livery.append(hFill(hPoly([(-160, -36), (160, -36), (160, 6), (-160, 6)]), 0x1D1F24, clip: true))
    livery.append(hFill(hPoly([(-160, 6), (160, 6), (160, 116), (-160, 116)]), 0x202227, clip: true))
    livery.append(hFill(hBox(0, -70, 40, 90, 6), 0x474A54, clip: true))
    livery.append(hFill(hBox(-74, -66, 17, 32, 4), brass, clip: true))
    livery.append(hFill(hBox(74, -66, 17, 32, 4), brass, clip: true))
    livery.append(hFill(shield, red, clip: true))
    livery.append(hLine(hPoly(trim, closed: false), brass, 9, clip: true))

    var dynamics: [HDynamic] = []
    // Gesture 0: the shield catches a headlight.
    dynamics.append(hLamp([hFill(shield, 0xFFB5A6)], gesture: 0))
    // Gesture 2: a light runs along the reflective trim of the brim.
    dynamics += hChase(HShape.spans(hPoly(trim, closed: false)), hex: 0xFFEFB8, width: 9, gesture: 2, clip: true)
    // Gesture 3: the hood is pulled up over the mouth.
    dynamics.append(HDynamic(
        draws: [hFill(hBox(0, 92, 190, 40), 0x34373F), hLine(hPoly([(-86, 74), (86, 74)], closed: false), 0x6A6E7A, 8)],
        channel: .gesture(3), opacity: HRamp(0, 1), offsetY: HRamp(0, -32), insideWindow: true
    ))


    // Gesture 4: the brass pads on the crown flash like a siren, red on the left and white on the right.
    dynamics.append(hGlow([hFill(hBox(-74, -66, 17, 32, 4), 0xFF4B3E, clip: true)], gesture: 4, center: 1.0 / 3, width: 1.0 / 3))
    dynamics.append(hGlow([hFill(hBox(74, -66, 17, 32, 4), 0xFFF6E0, clip: true)], gesture: 4, center: 2.0 / 3, width: 1.0 / 3))
    // Gesture 5: smoke rises past the face.
    dynamics.append(HDynamic(
        draws: [hFill(hTogether([hOval(-52, 78, 50, 34), hOval(0, 86, 60, 40), hOval(54, 80, 50, 34)]), 0xA9AFBA, 0.6)],
        channel: .gesture(5), opacity: HRamp(0, 1), offsetY: HRamp(0, -46), insideWindow: true,
        pulse: HPulse(center: 0.5, width: 0.5)
    ))
    // Gesture 6: embers lift off the brim.
    for (x, y, run, drift) in [(-122, -22, 56, -10), (-92, -20, 44, 6), (98, -22, 50, -6), (128, -24, 60, 12)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
        dynamics.append(HDynamic(
            draws: [hFill(hPoly([(x, y - 8), (x + 6, y), (x, y + 8), (x - 6, y)]), 0xFF8A3D)],
            channel: .gesture(6), opacity: HRamp(0, 1), offsetX: HRamp(0, drift), offsetY: HRamp(0, -run),
            pulse: HPulse(center: 0.5, width: 0.5)
        ))
    }
    // Gesture 7: water drips from the brim.
    for (x, run) in [(-140, 38), (-104, 30), (110, 34), (144, 42)] as [(CGFloat, CGFloat)] {
        dynamics.append(HDynamic(
            draws: [hFill(hOval(x, 6, 11, 16), 0x9ED6FF)],
            channel: .gesture(7), opacity: HRamp(0, 1), offsetY: HRamp(0, run),
            pulse: HPulse(center: 0.5, width: 0.5)
        ))
    }

    let spec = hHelmet(
        shell: shell, base: 0x2D2F36, light: 0x4B4E58,
        lightPath: hCurve([(-102, -38), (-102, -78), (-76, -106), (-30, -110)]), edge: 0xF2BBAA,
        livery: livery,
        window: hBox(0, 44, 160, 62, 24), top: 13, bottom: 75, width: 160,
        rim: 0x0C0D10, rimWidth: 10,
        eyes: (w: 30, h: 32, y: 44, dx: 42, tx: 12, ty: 5, dim: 0xF3E6D2, bright: 0xFFFBF0),
        plate: (fill: 0x5C4A22, edge: brass, width: 4,
                deco: [hFill(hPoly([(-88, -36), (-54, -36), (-78, 36), (-112, 36)]), 0x7F6730)]),
        flash: 0xFFEFB8, flashGesture: 1,
        above: [], dynamics: dynamics,
        visorNudge: 0.42, visorGesture: 1
    )
    let gestures: [[SignatureStep]] = [
        // The shield catches a headlight, twice, and the eyes look up at it.
        [
            hs(0.06, hold: 0.03, ch: 0, lv: 1, gx: 0, gy: -0.8),
            hs(0.10, hold: 0.05, .easeIn, ch: 0, lv: 0),
            hs(0.06, hold: 0.03, ch: 0, lv: 1),
            hs(0.12, .easeIn, ch: 0, lv: 0, gx: 0, gy: 0),
        ],
        // The face shield dips and its brass edge flashes.
        [
            hs(0.14, hold: 0.16, ch: 1, lv: 1, dil: 0.9),
            hs(0.16, .easeIn, ch: 1, lv: 0, dil: 1),
        ],
        // A light runs along the brim.
        hWalk([0.25, 0.5, 0.75, 1], ch: 2, each: 0.1),
        // The hood comes up over the mouth and the eyes narrow behind it.
        [
            hs(0.12, hold: 0.2, ch: 3, lv: 1, dil: 0.8),
            hs(0.16, .easeIn, ch: 3, lv: 0, dil: 1),
        ],
        // The pads on the crown flash like a siren, red then white, twice, and the eyes look up at them.
        [
            hs(0.07, .linear, ch: 4, lv: 1.0 / 3, gx: 0, gy: -0.8),
            hs(0.07, .linear, ch: 4, lv: 2.0 / 3),
            hs(0.07, .linear, ch: 4, lv: 1.0 / 3),
            hs(0.07, .linear, ch: 4, lv: 2.0 / 3),
            hs(0.10, .linear, ch: 4, lv: 1, gx: 0, gy: 0),
            hReset(4),
        ],
        // Smoke rises past the face and the eyes narrow.
        [
            hs(0.12, hold: 0.08, ch: 5, lv: 0.5, dil: 0.85),
            hs(0.16, .easeIn, ch: 5, lv: 1, dil: 1),
            hReset(5),
        ],
        // Embers lift off the brim and the eyes watch them go up.
        [
            hs(0.14, hold: 0.06, ch: 6, lv: 0.5, gx: 0, gy: -0.7),
            hs(0.16, ch: 6, lv: 1, gx: 0, gy: 0),
            hReset(6),
        ],
        // Water drips off the brim and the eyes drop with it.
        [
            hs(0.12, hold: 0.06, ch: 7, lv: 0.5, gx: 0, gy: 0.6),
            hs(0.16, .easeIn, ch: 7, lv: 1, gx: 0, gy: 0),
            hReset(7),
        ],
    ]
    return HelmetEntry(spec: spec, gestures: gestures, reference: "Traditional fire helmet: comb crown, front shield, wide brim, face shield")
}

// MARK: - Diver

/// A brass diving helmet: the sphere, the round front window, the side ports and
/// the wing nuts that hold it to the breastplate. The front port's cover is the lid.
private func diverHelmet() -> HelmetEntry {
    let shell = hSym([
        (0, -112, 0), (58, -104, 36), (92, -70, 36), (104, -24, 24), (100, 34, 8),
        (96, 52, 4), (146, 66, 14), (156, 98, 12), (150, 112, 6), (0, 112, 0),
    ])
    let nuts: [CGFloat] = [-126, -90, -54, -18, 18, 54, 90, 126]
    let sidePorts = hTogether([hOval(-86, -8, 26, 46), hOval(86, -8, 26, 46)])

    var livery: [HDraw] = []
    livery.append(hFill(hPoly([(-160, 48), (160, 48), (160, 70), (-160, 70)]), 0x3F2F17, clip: true))
    livery.append(hFill(hDots(nuts, 84, 15), 0xD3B565, clip: true))

    var above: [HDraw] = []
    above.append(hFill(sidePorts, 0x0B0C0F))
    above.append(hLine(sidePorts, 0xC9A24A, 7))
    above.append(hFill(hOval(106, -58, 26, 26), 0x3F2F17))
    above.append(hLine(hOval(106, -58, 26, 26), 0xC9A24A, 7))

    var dynamics: [HDynamic] = []
    // Gesture 0: bubbles leave the exhaust valve and rise, one after another.
    let bubbleX: [CGFloat] = [124, 138, 128]
    for (index, x) in bubbleX.enumerated() {
        dynamics.append(HDynamic(
            draws: [hFill(hOval(x, -62, 15, 15), 0xC8F1EA)], channel: .gesture(0), opacity: HRamp(0, 1),
            offsetY: HRamp(18, -48),
            pulse: HPulse(center: CGFloat(index + 1) / 4, width: 0.25)
        ))
    }
    // Gesture 1: the wing nuts light in pairs, left to right.
    for pair in 0..<4 {
        let xs = [nuts[pair * 2], nuts[pair * 2 + 1]]
        dynamics.append(hGlow([hFill(hDots(xs, 84, 15), 0xFFF0B8, clip: true)], gesture: 1,
                              center: CGFloat(pair + 1) / 5, width: 0.2))
    }
    // Gesture 3: the spit cock turns a quarter, and is turned back.
    dynamics.append(HDynamic(
        draws: [hFill(hBox(70, 44, 34, 11, 5), 0xE7CD8A)], channel: .gesture(3),
        rotation: HRamp(0, 90), pivot: CGPoint(x: 70, y: 44)
    ))


    // Gesture 4: shafts of sunlight slant across the glass and drift.
    dynamics.append(HDynamic(
        draws: [hFill(hTogether([
            hPoly([(-48, -70), (-34, -70), (-14, 50), (-28, 50)]),
            hPoly([(-4, -70), (6, -70), (26, 50), (16, 50)]),
            hPoly([(30, -70), (50, -70), (70, 50), (50, 50)]),
        ]), 0xCFF5FF, 0.22)],
        channel: .gesture(4), opacity: HRamp(0, 1), offsetX: HRamp(-14, 22), insideWindow: true,
        pulse: HPulse(center: 0.5, width: 0.5)
    ))
    // Gesture 5: a fish swims across the glass. At rest it is off the glass on the left.
    dynamics.append(HDynamic(
        draws: [
            hFill(hOval(-112, -36, 44, 24), 0xE8803A),
            hFill(hPoly([(-132, -36), (-152, -48), (-152, -24)]), 0xE8803A),
            hFill(hOval(-100, -40, 6, 6), 0x0B0C0F),
        ],
        channel: .gesture(5), offsetX: HRamp(0, 240), insideWindow: true
    ))
    // Gesture 6: sunlight glints round the brass rim of the window.
    dynamics += hChase(HShape.spans(hOval(0, -8, 126, 92)), hex: 0xFFEBB0, width: 12, gesture: 6)
    // Gesture 7: the side ports catch the light, left then right.
    dynamics.append(hGlow([hFill(hOval(-86, -8, 20, 40), 0xBFF3FF, 0.9)], gesture: 7, center: 1.0 / 3, width: 1.0 / 3))
    dynamics.append(hGlow([hFill(hOval(86, -8, 20, 40), 0xBFF3FF, 0.9)], gesture: 7, center: 2.0 / 3, width: 1.0 / 3))

    let spec = hHelmet(
        shell: shell, base: 0x5C4623, light: 0x9A7B3E,
        lightPath: hCurve([(-96, 10), (-98, -34), (-72, -88), (-30, -108)]), edge: 0xF0D9A0,
        shade: 38, lit: (-40, -50, 270, 236),
        livery: livery,
        window: hOval(0, -8, 126, 92), top: -54, bottom: 38, width: 126,
        rim: 0xB68D3E, rimWidth: 16,
        eyes: (w: 26, h: 32, y: -8, dx: 30, tx: 9, ty: 5, dim: 0xDDEBE6, bright: 0xFFFFFF),
        glint: [hLine(hPoly([(-46, 10), (-46, -14), (-30, -30)], closed: false), 0xFFFFFF, 6, 0.16)],
        plate: (fill: 0x6B5128, edge: 0xE0C070, width: 5,
                deco: [hFill(hPoly([(-50, -51), (-22, -51), (-42, 51), (-70, 51)]), 0x8E7237)]),
        flash: 0xFFF1C2, flashGesture: 2,
        above: above, dynamics: dynamics,
        visorNudge: 0.4, visorGesture: 2
    )
    let gestures: [[SignatureStep]] = [
        // Bubbles rise from the exhaust valve; the eyes follow them up.
        [
            hs(0.08, .linear, ch: 0, lv: 0.25, gx: 0.7, gy: -0.5),
            hs(0.08, .linear, ch: 0, lv: 0.5),
            hs(0.08, .linear, ch: 0, lv: 0.75),
            hs(0.08, .linear, ch: 0, lv: 1, gx: 0, gy: 0),
            hReset(0),
        ],
        // The wing nuts light round the collar.
        hWalk([0.2, 0.4, 0.6, 0.8, 1], ch: 1, each: 0.08),
        // The front window swings half shut and back.
        [
            hs(0.14, hold: 0.16, ch: 2, lv: 1, dil: 0.9),
            hs(0.16, .easeIn, ch: 2, lv: 0, dil: 1),
        ],
        // The eyes check the spit cock while it turns a quarter.
        [
            hs(0.07, hold: 0.04, ch: 3, lv: 0.5, gx: 0.8, gy: 0.6),
            hs(0.07, hold: 0.1, ch: 3, lv: 1),
            hs(0.12, .easeInOut, ch: 3, lv: 0, gx: 0, gy: 0),
        ],
        // Shafts of sunlight drift across the glass and the eyes look up at them.
        [
            hs(0.14, hold: 0.06, ch: 4, lv: 0.5, gx: 0.3, gy: -0.7),
            hs(0.18, .easeIn, ch: 4, lv: 1, gx: 0, gy: 0),
            hReset(4),
        ],
        // A fish swims across and the eyes follow it from side to side.
        [
            hs(0.04, hold: 0.03, gx: -0.7, gy: -0.5),
            hs(0.17, .linear, ch: 5, lv: 0.5, gx: 0, gy: -0.5),
            hs(0.17, .linear, ch: 5, lv: 1, gx: 0.7, gy: -0.5),
            hReset(5),
            hs(0.08, gx: 0, gy: 0),
        ],
        // Light runs round the brass rim.
        hWalk([0.2, 0.4, 0.6, 0.8, 1], ch: 6, each: 0.08),
        // The side ports flash, left then right, and the eyes glance at each.
        [
            hs(0.07, hold: 0.1, ch: 7, lv: 1.0 / 3, gx: -0.8, gy: 0),
            hs(0.08, hold: 0.1, ch: 7, lv: 2.0 / 3, gx: 0.8, gy: 0),
            hs(0.1, ch: 7, lv: 1, gx: 0, gy: 0),
            hReset(7),
        ],
    ]
    return HelmetEntry(spec: spec, gestures: gestures, reference: "Brass standard diving helmet: round front port, side ports, wing nuts, spit cock")
}

// MARK: - Kabuto

/// A samurai kabuto: the crescent crest on a low dome, the folded-back wing
/// flaps, the lacing of the neck guard. The brow plate is the lid.
private func kabutoHelmet() -> HelmetEntry {
    let shell = hSym([
        (0, -74, 0), (38, -92, 0), (70, -112, 2), (58, -84, 0), (46, -64, 0),
        (88, -56, 20), (116, -34, 16), (118, -6, 4), (152, 98, 8), (146, 112, 6), (0, 112, 0),
    ])
    let gold: UInt32 = 0xC9A04A
    let crest = hPoly([(-160, -120), (160, -120), (160, -64), (-160, -64)])
    let laces: [CGFloat] = [80, 93, 106]
    let flapR: HPath = hPoly([(106, -50), (140, -66), (152, -38), (124, -14), (108, -22)])

    var livery: [HDraw] = []
    livery.append(hFill(crest, gold, clip: true))
    livery.append(hFill(hPoly([(-160, 66), (160, 66), (160, 116), (-160, 116)]), 0x1B1C21, clip: true))
    for y in laces { livery.append(hLine(hPoly([(-160, y), (160, y)], closed: false), 0x9A3A33, 7, clip: true)) }
    livery.append(hLine(hCurve([(-104, -34), (-60, -52), (0, -58), (60, -52), (104, -34)]), 0x3F424B, 7, clip: true))

    var dynamics: [HDynamic] = []
    // Gesture 0: the crest catches the light.
    dynamics.append(hLamp([hFill(crest, 0xFFE9A8, clip: true)], gesture: 0))
    // Gesture 1: a light runs down the lacing, row by row.
    for (index, y) in laces.enumerated() {
        dynamics.append(hGlow([hLine(hPoly([(-160, y), (160, y)], closed: false), 0xFFB9A8, 7, clip: true)], gesture: 1,
                              center: CGFloat(index + 1) / 4, width: 0.25))
    }
    // Gesture 2: the wing flaps spread.
    let flapL = hMirror(flapR)
    dynamics.append(HDynamic(
        draws: [hFill(flapR, 0x2B2D34), hLine(flapR, 0xCDB68A, 6), hFill(hBox(130, -40, 12, 12, 3), gold)],
        channel: .gesture(2), rotation: HRamp(0, -28), pivot: CGPoint(x: 106, y: -30)
    ))
    dynamics.append(HDynamic(
        draws: [hFill(flapL, 0x2B2D34), hLine(flapL, 0xCDB68A, 6), hFill(hBox(-130, -40, 12, 12, 3), gold)],
        channel: .gesture(2), rotation: HRamp(0, 28), pivot: CGPoint(x: -106, y: -30)
    ))


    // Gesture 4: a sword cut across the face, white, from the upper right to the lower left.
    dynamics.append(HDynamic(
        draws: [
            hLine(hPoly([(112, -30), (-112, 74)], closed: false), 0xF4F6FA, 8, clip: true),
            hLine(hPoly([(124, -14), (-100, 90)], closed: false), 0xF4F6FA, 4, clip: true),
        ],
        channel: .gesture(4), opacity: HRamp(0, 1)
    ))
    // Gesture 5: three petals of cherry blossom fall across the front, turning as they go.
    for (x, y, dx, dy, turn) in [(-96, -80, 30, 110, 140), (-20, -96, -24, 120, -120), (64, -88, 26, 104, 160)] as [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] {
        dynamics.append(HDynamic(
            draws: [hFill(hOval(x, y, 20, 12), 0xF4B6C8)],
            channel: .gesture(5), opacity: HRamp(0, 1), offsetX: HRamp(0, dx), offsetY: HRamp(0, dy),
            rotation: HRamp(0, turn), pivot: CGPoint(x: x, y: y), pulse: HPulse(center: 0.5, width: 0.5)
        ))
    }
    // Gesture 6: a glint slides along the gold crescent. It fades in and out so it never leaves the gold.
    dynamics.append(HDynamic(
        draws: [hFill(hPoly([(-30, -120), (14, -120), (-2, -64), (-46, -64)]), 0xFFF6D8, 0.95, clip: true)],
        channel: .gesture(6), opacity: HRamp(0, 1), offsetX: HRamp(-70, 70), pulse: HPulse(center: 0.5, width: 0.5)
    ))
    // Gesture 7: a kiai, the shout: lines flare either side of the face.
    let shoutLeft = hTogether([
        hPoly([(-128, 8), (-108, 16)], closed: false),
        hPoly([(-132, 30), (-110, 30)], closed: false),
        hPoly([(-128, 52), (-108, 44)], closed: false),
    ])
    dynamics.append(HDynamic(
        draws: [hLine(shoutLeft, 0xF1E6CB, 7), hLine(hMirror(shoutLeft), 0xF1E6CB, 7)],
        channel: .gesture(7), opacity: HRamp(0, 1), scale: HRamp(0.7, 1.1), pivot: CGPoint(x: 0, y: 30),
        pulse: HPulse(center: 0.5, width: 0.5)
    ))

    let spec = hHelmet(
        shell: shell, base: 0x26282E, light: 0x484B55,
        lightPath: hCurve([(-112, -30), (-96, -52), (-60, -62), (-46, -66)]), edge: 0xE6D2A4,
        shade: 38, lit: (-40, -50, 280, 230),
        livery: livery,
        window: hBox(0, 30, 150, 64, 30), top: -2, bottom: 62, width: 150,
        rim: 0x0B0C0E, rimWidth: 10,
        eyes: (w: 32, h: 36, y: 30, dx: 40, tx: 12, ty: 5, dim: 0xF0E4CB, bright: 0xFFFBF0),
        plate: (fill: 0x3A3D47, edge: gold, width: 4,
                deco: [hFill(hPoly([(-70, -37), (-40, -37), (-60, 37), (-90, 37)]), 0x525661)]),
        flash: 0xFFE9A8, flashGesture: 3,
        above: [], dynamics: dynamics,
        visorNudge: 0.34, visorGesture: 3
    )
    let gestures: [[SignatureStep]] = [
        // The crest catches the light and the eyes look up at it.
        [
            hs(0.07, hold: 0.1, ch: 0, lv: 1, gx: 0, gy: -0.8),
            hs(0.14, .easeIn, ch: 0, lv: 0, gx: 0, gy: 0),
        ],
        // A light runs down the lacing.
        hWalk([0.25, 0.5, 0.75, 1], ch: 1, each: 0.1),
        // The wing flaps spread and fold again.
        [
            hs(0.12, hold: 0.14, .easeOut, ch: 2, lv: 1),
            hs(0.18, .easeInOut, ch: 2, lv: 0),
        ],
        // The brow plate scowls: it dips, its edge flashes and the eyes narrow.
        [
            hs(0.1, hold: 0.18, ch: 3, lv: 1, dil: 0.8),
            hs(0.16, .easeIn, ch: 3, lv: 0, dil: 1),
        ],
        // A sword cut: the eyes jump right, the slash flashes across the face and they snap to the left.
        [
            hs(0.04, hold: 0.04, gx: 0.8, gy: 0),
            hs(0.03, hold: 0.12, ch: 4, lv: 1, gx: -0.8, gy: 0),
            hs(0.16, .easeIn, ch: 4, lv: 0, gx: 0, gy: 0),
        ],
        // Petals of cherry blossom fall across the helmet and the eyes drift down with them.
        [
            hs(0.17, hold: 0.04, ch: 5, lv: 0.5, gx: 0.3, gy: 0.5),
            hs(0.17, .easeIn, ch: 5, lv: 1, gx: 0, gy: 0),
            hReset(5),
        ],
        // A glint slides along the gold crescent, and the eyes look up at it.
        [
            hs(0.09, .linear, ch: 6, lv: 0.25, gx: 0, gy: -0.8),
            hs(0.09, .linear, ch: 6, lv: 0.5),
            hs(0.09, .linear, ch: 6, lv: 0.75),
            hs(0.09, .linear, ch: 6, lv: 1, gx: 0, gy: 0),
            hReset(6),
        ],
        // A kiai: the eyes go wide, the shout lines flare, and it is over.
        [
            hs(0.06, hold: 0.16, ch: 7, lv: 0.5, dil: 1.2),
            hs(0.10, .easeIn, ch: 7, lv: 1, dil: 1),
            hReset(7),
        ],
    ]
    return HelmetEntry(spec: spec, gestures: gestures, reference: "Samurai kabuto: crescent maedate, fukigaeshi wing flaps, laced shikoro neck guard, mabizashi brow plate")
}

// MARK: - Great helm

/// A flat-topped great helm, the barrel of a helmet with a cross-shaped slit
/// that the eyes look out of. The plate is the shutter that slams.
private func greatHelm() -> HelmetEntry {
    let shell = hSym([
        (0, -110, 0), (66, -110, 12), (80, -100, 10), (86, -60, 0), (98, 20, 0), (112, 84, 8), (110, 112, 6), (0, 112, 0),
    ])
    let cross = hRound([
        (-13, -62, 3), (13, -62, 3), (13, -38, 0), (62, -38, 3), (62, -8, 3), (13, -8, 0),
        (13, 70, 3), (-13, 70, 3), (-13, -8, 0), (-62, -8, 3), (-62, -38, 3), (-13, -38, 0),
    ])
    let rust: UInt32 = 0xC0492B
    let band = hBox(0, -23, 320, 48)
    let spine = hBox(0, 0, 40, 240)
    let breaths = hTogether([-56, -36, 36, 56].flatMap { x in [24, 44, 64].map { y in hOval(CGFloat(x), CGFloat(y), 10, 10) } })
    let rivetGroups: [[(CGFloat, CGFloat)]] = [
        [(-60, -84), (-74, -58)], [(60, -84), (74, -58)], [(88, 34), (82, 80)], [(-88, 34), (-82, 80)],
    ]
    let rivets = hTogether(rivetGroups.flatMap { $0 }.map { hOval($0.0, $0.1, 11, 11) })

    var livery: [HDraw] = []
    livery.append(hFill(hBox(0, -104, 260, 16), 0x2A2F37, clip: true))
    livery.append(hFill(band, 0x414955, clip: true))
    livery.append(hFill(spine, 0x414955, clip: true))
    livery.append(hFill(hBox(0, 106, 320, 14), rust, clip: true))
    livery.append(hFill(breaths, 0x0B0C0F, clip: true))
    livery.append(hFill(rivets, 0x8A95A5, clip: true))

    var dynamics: [HDynamic] = []
    // Gesture 0: the crossing bands flash, the horizontal one, then the upright.
    dynamics.append(hGlow([hFill(band, 0xC6D6EA, 0.6, clip: true)], gesture: 0, center: 1.0 / 3, width: 1.0 / 3))
    dynamics.append(hGlow([hFill(spine, 0xC6D6EA, 0.6, clip: true)], gesture: 0, center: 2.0 / 3, width: 1.0 / 3))
    // Gesture 1: the rivets light round the face, two at a time, clockwise.
    for (index, group) in rivetGroups.enumerated() {
        dynamics.append(hGlow([hFill(hTogether(group.map { hOval($0.0, $0.1, 11, 11) }), 0xFFF3C8, clip: true)],
                              gesture: 1, center: CGFloat(index + 1) / 5, width: 0.2))
    }
    // Gesture 3: the breaths puff.
    dynamics.append(hLamp([hFill(breaths, 0xDDEBFF, clip: true)], gesture: 3))


    // Gesture 4: an arrow whistles past from the right, through the line of the band.
    dynamics.append(HDynamic(
        draws: [
            hLine(hPoly([(50, -23), (150, -23)], closed: false), 0xC9B58A, 7),
            hFill(hPoly([(50, -23), (68, -32), (68, -14)]), 0xDDE3EA),
            hLine(hTogether([hPoly([(150, -23), (136, -33)], closed: false), hPoly([(150, -23), (136, -13)], closed: false)]), 0xB04A3A, 6),
        ],
        channel: .gesture(4), opacity: HRamp(0, 1), offsetX: HRamp(0, -200), pulse: HPulse(center: 0.5, width: 0.5)
    ))
    // Gesture 5: a sword glances off the helm in a burst of sparks at the upper left.
    var sparks: [HPath] = []
    for k in 0..<6 {
        let a = Double(k) * Double.pi / 3 + 0.3
        sparks.append(hPoly([(-70 + CGFloat(7 * cos(a)), -92 + CGFloat(7 * sin(a))), (-70 + CGFloat(24 * cos(a)), -92 + CGFloat(24 * sin(a)))], closed: false))
    }
    dynamics.append(HDynamic(
        draws: [hLine(hTogether(sparks), 0xFFD76A, 6)],
        channel: .gesture(5), opacity: HRamp(0, 1), scale: HRamp(0.5, 1.3), pivot: CGPoint(x: -70, y: -92),
        pulse: HPulse(center: 0.5, width: 0.5)
    ))
    // Gesture 6: a torch is carried past: a warm slanted band crosses the helm from the left.
    dynamics.append(HDynamic(
        draws: [hFill(hPoly([(-40, -110), (20, -110), (0, 110), (-60, 110)]), 0xFFB347, 0.22, clip: true)],
        channel: .gesture(6), opacity: HRamp(0, 1), offsetX: HRamp(-50, 80), pulse: HPulse(center: 0.5, width: 0.5)
    ))
    // Gesture 7: the cross-shaped slit glows, white.
    dynamics.append(hLamp([hFill(cross, 0xF4F9FF, 0.55)], gesture: 7, inside: true))

    let spec = hHelmet(
        shell: shell, base: 0x343B45, light: 0x6A7482,
        lightPath: hCurve([(-84, -56), (-80, -98), (-60, -108), (-30, -108)]), edge: 0xD2DCE9,
        shade: 38, lit: (-48, -46, 280, 250),
        livery: livery,
        window: cross, top: -62, bottom: 70, width: 124,
        rim: 0x14171B, rimWidth: 9, restFraction: 0.17,
        eyes: (w: 26, h: 20, y: -23, dx: 38, tx: 6, ty: 2, dim: 0xE9EDF2, bright: 0xFFFFFF),
        plate: (fill: 0x1E2328, edge: 0xB7C3D2, width: 4, deco: []),
        flash: 0xF2F7FF, flashGesture: 2,
        above: [], dynamics: dynamics,
        visorNudge: 0.29, visorGesture: 2
    )
    let gestures: [[SignatureStep]] = [
        // The horizontal band flashes, then the upright.
        hWalk([1.0 / 3, 2.0 / 3, 1], ch: 0, each: 0.11),
        // The rivets light round the face.
        hWalk([0.2, 0.4, 0.6, 0.8, 1], ch: 1, each: 0.08),
        // The visor slams shut over the slit and the eyes blink behind it.
        [
            hs(0.05, hold: 0.2, ch: 2, lv: 1),
            hs(0.14, .easeInOut, ch: 2, lv: 0),
        ],
        // The breaths puff, twice, and the eyes close up.
        [
            hs(0.07, hold: 0.04, ch: 3, lv: 1, dil: 0.85),
            hs(0.1, hold: 0.03, .easeIn, ch: 3, lv: 0),
            hs(0.07, hold: 0.04, ch: 3, lv: 1),
            hs(0.12, .easeIn, ch: 3, lv: 0, dil: 1),
        ],
        // An arrow whistles past, right to left, and the eyes flick after it.
        [
            hs(0.04, hold: 0.10, gx: 0.8, gy: 0),
            hs(0.10, .linear, ch: 4, lv: 0.5, gx: 0, gy: 0),
            hs(0.10, .linear, ch: 4, lv: 1, gx: -0.8, gy: 0),
            hReset(4),
            hs(0.10, gx: 0, gy: 0),
        ],
        // A sword glances off the helm: sparks, and the eyes screw up.
        [
            hs(0.10, hold: 0.06, ch: 5, lv: 0.5, dil: 0.8),
            hs(0.14, .easeIn, ch: 5, lv: 1, dil: 1),
            hReset(5),
        ],
        // A torch is carried past and the eyes follow its light across.
        [
            hs(0.04, hold: 0.04, gx: -0.8, gy: 0),
            hs(0.14, .linear, ch: 6, lv: 0.5, gx: 0, gy: 0),
            hs(0.14, .linear, ch: 6, lv: 1, gx: 0.8, gy: 0),
            hReset(6),
            hs(0.08, gx: 0, gy: 0),
        ],
        // The cross glows and the eyes close up behind it.
        [
            hs(0.16, hold: 0.2, ch: 7, lv: 1, dil: 0.85),
            hs(0.2, .easeInOut, ch: 7, lv: 0, dil: 1),
        ],
    ]
    return HelmetEntry(spec: spec, gestures: gestures, reference: "13th-century great helm: flat top, cross-shaped slit, breaths, riveted bands")
}
