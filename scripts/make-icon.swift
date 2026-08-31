#!/usr/bin/env swift
// Draw the app icon from code, so there is no binary asset to keep in sync.
//
// Renders AppIcon.iconset/ at every size macOS asks for. `make icon` turns that
// into Resources/AppIcon.icns with iconutil.
//
//   swift scripts/make-icon.swift
//   iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns

import AppKit
import Foundation

let sizes: [(Int, Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]

/// How the mark is drawn at a given apparent size.
///
/// Three optical sizes rather than one drawing scaled down. The icon this
/// replaced had a single geometry whose detail — a receding strip, five fading
/// dashes — dissolved below 32pt and left a green dot on dark, which is what
/// the Dock and the menu bar actually showed.
///
/// The notch stays pure black at every size, because a notch is the absence of
/// display and reads as a hole rather than an applied shape. What has to move
/// is the *ground*: black on the old #1C1F27 sits at a 1.27:1 contrast ratio,
/// below where an edge survives antialiasing. So as the canvas shrinks the
/// gradient lifts, the notch widens, and the dot — the only high-contrast
/// element in the mark — grows to carry the weight.
///
/// All measurements are fractions of the icon's side, so the geometry is
/// resolution-independent and @1x and @2x of the same point size agree.
struct Geometry {
    let notchWidth: CGFloat
    let notchDepth: CGFloat
    let dotRadius: CGFloat
    let gradientTop: NSColor
    let gradientBottom: NSColor

    static let live = NSColor(calibratedRed: 0.20, green: 0.82, blue: 0.42, alpha: 1)

    private static func hex(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(
            calibratedRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255, alpha: 1
        )
    }

    /// Selected by *points*, not pixels: what matters is how large the icon
    /// looks on screen, and 16pt@2x is still a 16pt icon.
    static func forPoints(_ points: Int) -> Geometry {
        switch points {
        case ...16:
            // The ground is lifted furthest here, and the notch is stretched
            // until it reads as a band rather than a shape: at 16px a 0.56-wide
            // notch is nine pixels of near-black on dark and disappears, while
            // a 0.70-wide one still registers as an interruption. Identity at
            // this size is "dark tile, bitten top edge, green light" — the
            // proportions of the real thing are a luxury of the large cuts.
            return Geometry(
                notchWidth: 0.70, notchDepth: 0.34, dotRadius: 0.13,
                gradientTop: hex(0x45, 0x4E, 0x5F), gradientBottom: hex(0x14, 0x17, 0x1E)
            )
        case 17...64:
            return Geometry(
                notchWidth: 0.58, notchDepth: 0.40, dotRadius: 0.115,
                gradientTop: hex(0x32, 0x39, 0x47), gradientBottom: hex(0x0F, 0x12, 0x18)
            )
        default:
            return Geometry(
                notchWidth: 0.56, notchDepth: 0.42, dotRadius: 0.10,
                gradientTop: hex(0x2B, 0x30, 0x3B), gradientBottom: hex(0x0D, 0x0F, 0x14)
            )
        }
    }
}

/// The mark: the notch the app lives in, cut from the top edge of a dark
/// display, with the status light where a MacBook keeps its camera.
func drawIcon(side: CGFloat, points: Int) -> NSImage {
    let geometry = Geometry.forPoints(points)
    let image = NSImage(size: CGSize(width: side, height: side))
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = CGRect(x: 0, y: 0, width: side, height: side)
    let radius = side * 0.2237  // Apple's continuous-corner ratio

    let background = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGradient(starting: geometry.gradientTop, ending: geometry.gradientBottom)?
        .draw(in: background, angle: -90)

    // The notch is flush with the icon's top edge, and near the corners that
    // edge is already curving away. Clipping to the squircle lets the notch be
    // as wide as legibility wants without poking outside the silhouette.
    NSGraphicsContext.saveGraphicsState()
    background.addClip()

    let width = side * geometry.notchWidth
    let depth = side * geometry.notchDepth
    let corner = depth / 2
    let left = (side - width) / 2
    let right = left + width
    let bottom = side - depth  // AppKit is y-up, so the icon's top edge is y = side.

    let notch = NSBezierPath()
    notch.move(to: CGPoint(x: left, y: side))
    notch.line(to: CGPoint(x: right, y: side))
    notch.appendArc(
        from: CGPoint(x: right, y: bottom), to: CGPoint(x: left, y: bottom), radius: corner
    )
    notch.appendArc(
        from: CGPoint(x: left, y: bottom), to: CGPoint(x: left, y: side), radius: corner
    )
    notch.close()
    NSColor.black.setFill()
    notch.fill()

    let dotRadius = side * geometry.dotRadius
    let centre = CGPoint(x: side / 2, y: side - depth / 2)
    let dot = NSBezierPath(ovalIn: CGRect(
        x: centre.x - dotRadius, y: centre.y - dotRadius,
        width: dotRadius * 2, height: dotRadius * 2
    ))
    Geometry.live.setFill()
    dot.fill()

    NSGraphicsContext.restoreGraphicsState()
    return image
}

let directory = URL(fileURLWithPath: "AppIcon.iconset")
try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

for (points, scale) in sizes {
    let pixels = CGFloat(points * scale)
    let image = drawIcon(side: pixels, points: points)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("failed to render \(points)@\(scale)x")
        exit(1)
    }
    let suffix = scale == 1 ? "" : "@\(scale)x"
    let name = "icon_\(points)x\(points)\(suffix).png"
    try png.write(to: directory.appendingPathComponent(name))
    print("  \(name)  \(Int(pixels))px")
}

print("wrote \(sizes.count) images to AppIcon.iconset/")
