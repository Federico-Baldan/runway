import SwiftUI

/// The island's silhouette — one shape for both displays it can land on.
///
/// ## The shoulders
///
/// Under a cutout the island used to be a plain rectangle with square top
/// corners, drawn at exactly the cutout's width. The union of that and the
/// camera housing is a rounded rectangle a little taller than the notch, and it
/// reads as what it is: a tab somebody hung off the hardware.
///
/// What makes the union read as *one object* is a concave fillet where the
/// island's sides meet the menu bar — the shape flares outwards as it reaches
/// the top of the screen instead of stopping dead. It is the same construction
/// the Dynamic Island uses, and the same one every notch app on the Mac has
/// converged on: concave at the top, convex at the bottom. Those two curvatures
/// meeting is the whole trick; without the concave half the eye finds the seam
/// immediately, because a right angle between two blacks is a boundary and a
/// fillet is not.
///
/// ## Why the width has to grow with it
///
/// The straight-sided part of the path is inset by `shoulder` on each side, so
/// a frame that is exactly the cutout's width would draw a *body* two shoulders
/// narrower than the cutout — a black seam either side, which is the rendering
/// fault `NotchMath.Width.resting` exists to prevent. The frame therefore
/// carries the flare as extra width: `restingBody` is what has to match the
/// cutout, and `resting` adds the shoulders back on. `spike/NotchPlacementVerify`
/// checks that relationship rather than the old bare equality.
struct IslandShape: InsettableShape {
    /// True when the island is tucked under a physical cutout.
    var hasNotch: Bool
    /// Width of the concave flare either side. Zero draws square shoulders.
    var shoulder: CGFloat
    /// The convex bottom corners.
    var bottomRadius: CGFloat
    /// Corner radius off a notch, where the island is a free-floating pill.
    var pillRadius: CGFloat = 14

    /// Accumulated by `inset(by:)`. Deliberately NOT private: a private stored
    /// property makes the synthesised memberwise initialiser private too, and
    /// `IslandView` is in another file.
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> IslandShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard box.width > 0, box.height > 0 else { return Path() }

        // Off a cutout there is nothing to blend into: a real window edge, so a
        // real rounded rectangle.
        guard hasNotch else {
            return Path(roundedRect: box, cornerRadius: pillRadius, style: .continuous)
        }

        // Clamped so a narrow cutout or a mid-animation frame degrades into a
        // plain rounded rectangle instead of a self-intersecting path.
        let flare = max(min(shoulder, box.width / 2 - 1), 0)
        let bodyWidth = box.width - flare * 2
        let corner = max(min(bottomRadius, bodyWidth / 2, box.height - flare), 0)

        let leftEdge = box.minX + flare
        let rightEdge = box.maxX - flare

        var path = Path()
        path.move(to: CGPoint(x: box.minX, y: box.minY))

        // Top left, concave: the fillet that turns the menu bar into the island.
        path.addQuadCurve(
            to: CGPoint(x: leftEdge, y: box.minY + flare),
            control: CGPoint(x: leftEdge, y: box.minY)
        )
        path.addLine(to: CGPoint(x: leftEdge, y: box.maxY - corner))

        // Bottom left, convex.
        path.addQuadCurve(
            to: CGPoint(x: leftEdge + corner, y: box.maxY),
            control: CGPoint(x: leftEdge, y: box.maxY)
        )
        path.addLine(to: CGPoint(x: rightEdge - corner, y: box.maxY))

        // Bottom right, convex.
        path.addQuadCurve(
            to: CGPoint(x: rightEdge, y: box.maxY - corner),
            control: CGPoint(x: rightEdge, y: box.maxY)
        )
        path.addLine(to: CGPoint(x: rightEdge, y: box.minY + flare))

        // Top right, concave.
        path.addQuadCurve(
            to: CGPoint(x: box.maxX, y: box.minY),
            control: CGPoint(x: rightEdge, y: box.minY)
        )

        path.closeSubpath()
        return path
    }
}
