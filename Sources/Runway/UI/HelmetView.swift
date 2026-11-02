import SwiftUI

// The SwiftUI half of the helmets: it turns the numbers in `HelmetSpec` into
// views and decides nothing. What a helmet looks like, how the visor and the
// LEDs move, and what the gestures do are all in Foundation-only files that
// are checked by `spike/HelmetVerify.swift`; if a helmet is wrong, it is wrong
// there and visible there.
//
// ## What it costs
//
// Nothing is redrawn while something moves. Every still part — the shell, the
// livery, the rim, the hardware, the visor itself — is a `Canvas` drawn once and
// held by `HelmetLayer`, which is `Equatable` so SwiftUI does not even evaluate
// it again when the eyes move. What moves is moved, not repainted: the LEDs by
// `offset` and `frame`, the visor by `offset`, the breath and the gestures by
// `opacity`, `scaleEffect`, `rotationEffect` and `offset`. Those are the
// properties the eye already animates, with the animations the animator already
// chooses, so a helmet adds no timer, no `TimelineView`, no `repeatForever`, and
// nothing the compositor has to blur. Nothing here interpolates anything itself:
// a part that must light in the middle of a gesture is given a level to pass
// through (see `HDynamic.pulse`), not a function of the channel.

extension HColor {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}

extension Path {
    init(_ segments: HPath) {
        self.init()
        for segment in segments {
            switch segment {
            case .move(let point): move(to: point)
            case .line(let point): addLine(to: point)
            case .curve(let to, let c1, let c2): addCurve(to: to, control1: c1, control2: c2)
            case .close: closeSubpath()
            }
        }
    }
}

/// An outline from the design space, scaled into whatever it is given. The
/// window uses it to clip what slides behind it.
struct HelmetOutline: Shape {
    let segments: HPath

    func path(in rect: CGRect) -> Path {
        let scale = rect.width / HelmetSpec.designWidth
        let transform = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY))
        return Path(segments).applying(transform)
    }
}

/// One still piece of a helmet.
struct HelmetLayer: View, Equatable {
    let style: AvatarStyle
    let spec: HelmetSpec
    let layer: HelmetLayerID

    /// By style and layer only. The spec is a function of the style, and
    /// comparing it would mean comparing every point of every outline.
    ///
    /// `nonisolated`, because `View` is main-actor isolated and Swift 6 refuses
    /// an isolated `==` as the witness for `Equatable`: the conformance "crosses
    /// into main actor-isolated code". It only reads two immutable, Sendable
    /// properties, so it needs no isolation.
    nonisolated static func == (a: HelmetLayer, b: HelmetLayer) -> Bool {
        a.style == b.style && a.layer == b.layer
    }

    var body: some View {
        // Locals, so the renderer captures two Sendable values and not `self`.
        // SwiftUI documents the renderer as a plain closure, neither `@Sendable`
        // nor `@MainActor`, and a literal formed here would otherwise be inferred
        // main-actor in Swift 6 and checked at run time against wherever it is called.
        let spec = self.spec
        let layer = self.layer
        Canvas { @Sendable context, size in
            let scale = size.width / HelmetSpec.designWidth
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.scaleBy(x: scale, y: scale)
            let shell = Path(HelmetSpec.shell)
            // `scale` is points per design unit: how much of the helmet is
            // worth drawing depends on how big it is on the screen.
            for draw in spec.draws(for: layer, pointsPerUnit: scale) {
                var inner = context
                if draw.clipToShell { inner.clip(to: shell) }
                let path = Path(draw.path)
                if let fill = draw.fill {
                    inner.fill(path, with: .color(fill.color), style: FillStyle(eoFill: draw.evenOdd))
                }
                if let stroke = draw.stroke {
                    inner.stroke(
                        path, with: .color(stroke.color),
                        style: StrokeStyle(lineWidth: draw.strokeWidth, lineCap: .round, lineJoin: .round)
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// A helmet, wearing whatever the animator is doing.
///
/// The same view draws the resting mark, and — with no animator and no
/// animations — the still previews in Settings.
struct HelmetMark: View {
    let style: AvatarStyle
    let spec: HelmetSpec
    /// Height of the mark in points. The width follows from the notch's aspect.
    var height: CGFloat
    var eye = IdleMarkAnimator.Eye()
    var led: CGFloat = 0
    /// One channel per gesture, each 0 at rest.
    var gestures = [CGFloat](repeating: 0, count: HelmetState.gestureSlots)
    /// The animations the animator chose for the next change of each channel,
    /// scoped to that channel the way `IdleMark` scopes them for the eye, so a
    /// 60ms blink is never re-timed by whatever the island is animating above it.
    var motion: Animation?
    var ledMotion: Animation?
    var gestureMotion: Animation?
    /// Somebody is looking: the LEDs stay lit.
    var isAttentive = false

    private var width: CGFloat { (height * BrandGeometry.aspect).rounded() }

    private var scale: CGFloat {
        assert(
            HelmetSpec.topCornerRatio == BrandGeometry.topCornerRatio
                && HelmetSpec.designWidth / HelmetSpec.designHeight == BrandGeometry.aspect,
            "HelmetSpec's notch no longer matches BrandGeometry"
        )
        return width / HelmetSpec.designWidth
    }

    private var state: HelmetState {
        HelmetState(
            lid: eye.lid,
            gazeX: eye.gaze.width,
            gazeY: eye.gaze.height,
            dilation: eye.dilation,
            led: isAttentive ? max(led, 0.7) : led,
            gestures: gestures
        )
    }

    private var insideWindow: [Int] { spec.dynamics.indices.filter { spec.dynamics[$0].insideWindow } }
    private var outsideWindow: [Int] { spec.dynamics.indices.filter { !spec.dynamics[$0].insideWindow } }

    var body: some View {
        let s = state
        ZStack {
            still(.below)
            window(s)
            still(.rim)
            still(.above)
            still(.edge)
            ForEach(outsideWindow, id: \.self) { moving($0, s) }
        }
        .frame(width: width, height: height)
        // Only the eye's own channel is scoped out here. The breath and the
        // gestures scope their own properties further in, because `.animation`
        // applies from the outside in and the one nearest the view wins when two
        // values change in the same turn: a breath rising with a blink, a gesture
        // starting with a breath. Stacked out here, the nearest would time
        // everything, and a 160ms visor lift would run on the breath's 1.1s curve.
        // The classic mark scopes the same way, for the same reason.
        .animation(motion, value: eye)
    }

    private func still(_ layer: HelmetLayerID) -> some View {
        HelmetLayer(style: style, spec: spec, layer: layer).equatable()
    }

    /// Everything that slides behind the rim: the eyes, the glint, the sun
    /// visor. Clipped to the window, so none of it can be seen outside it.
    private func window(_ s: HelmetState) -> some View {
        ZStack {
            still(.glass)
            eyes(s)
            still(.highlights)
                .offset(x: -s.gazeX * 5 * scale, y: -s.gazeY * 3 * scale)
            ZStack {
                // The visor rests above the notch's top edge, so its Canvas is
                // twice as tall as the mark and then framed back to size: a Canvas
                // draws only inside its own frame, and a visor moved down with its
                // top never drawn leaves the top of the window bare. The second
                // frame keeps the layout size, so nothing else shifts.
                still(.plate)
                    .frame(width: width, height: height * 2)
                    .frame(width: width, height: height)
                if spec.plate.edgeFlash != nil {
                    still(.plateFlash).opacity(Double(s.gesture(spec.plate.flashGesture)))
                }
            }
            .offset(y: spec.plateOffsetY(s) * scale)
            // Inside the root's `motion`: it wins only when a gesture moved.
            .animation(gestureMotion, value: s.gestures)
            ForEach(insideWindow, id: \.self) { moving($0, s) }
        }
        .clipShape(HelmetOutline(segments: spec.window.path))
    }

    /// The two LEDs. The brighter copy fades in over the dim one with the
    /// breath: one fill changing opacity, nothing to redraw.
    private func eyes(_ s: HelmetState) -> some View {
        let rects = spec.eyeRects(s)
        return ZStack {
            ForEach(rects.indices, id: \.self) { index in
                let rect = rects[index]
                let radius = spec.eyeCornerRadius(for: rect) * scale
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(spec.eyes.dim.color)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(spec.eyes.bright.color)
                            .opacity(Double(s.led))
                            .animation(ledMotion, value: s.led)
                    }
                    .frame(width: rect.width * scale, height: rect.height * scale)
                    .offset(x: rect.midX * scale, y: rect.midY * scale)
            }
        }
    }

    /// A part that answers to the breath or to a gesture: a still, moved.
    private func moving(_ index: Int, _ s: HelmetState) -> some View {
        let part = spec.dynamics[index]
        let m = spec.motion(of: part, in: s)
        let anchor = UnitPoint(
            x: 0.5 + part.pivot.x / HelmetSpec.designWidth,
            y: 0.5 + part.pivot.y / HelmetSpec.designHeight
        )
        let channelValue: [CGFloat] = part.channel == .led ? [s.led] : s.gestures
        let channelMotion: Animation? = part.channel == .led ? ledMotion : gestureMotion
        return still(.dynamic(index))
            .scaleEffect(m.scale, anchor: anchor)
            .rotationEffect(.degrees(Double(m.rotation)), anchor: anchor)
            .offset(x: m.dx * scale, y: m.dy * scale)
            .opacity(Double(m.opacity))
            .animation(channelMotion, value: channelValue)
    }
}

/// What a style looks like, for a picker: the helmet at rest, or the original
/// eye drawn the way the mark draws it.
struct AvatarPreview: View {
    let style: AvatarStyle
    var height: CGFloat = 32

    var body: some View {
        if let spec = style.helmet {
            HelmetMark(style: style, spec: spec, height: height)
        } else {
            ClassicEyePreview(height: height)
        }
    }
}

private struct ClassicEyePreview: View {
    let height: CGFloat

    var body: some View {
        let width = (height * BrandGeometry.aspect).rounded()
        let eye = (height * BrandGeometry.eyeRatio).rounded()
        ZStack {
            UnevenRoundedRectangle(
                topLeadingRadius: width * BrandGeometry.topCornerRatio,
                bottomLeadingRadius: height / 2,
                bottomTrailingRadius: height / 2,
                topTrailingRadius: width * BrandGeometry.topCornerRatio,
                style: .continuous
            )
            .fill(Color.white.opacity(0.13))
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.78))
                .frame(width: eye, height: eye)
        }
        .frame(width: width, height: height)
    }
}
