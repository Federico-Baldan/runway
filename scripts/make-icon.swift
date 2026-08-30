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

/// The mark: a dark rounded square with a runway light strip receding into it,
/// and one live green touchdown dot. Reads at 16pt as a dot on dark.
func drawIcon(side: CGFloat) -> NSImage {
    let image = NSImage(size: CGSize(width: side, height: side))
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = CGRect(x: 0, y: 0, width: side, height: side)
    let radius = side * 0.2237  // Apple's continuous-corner ratio

    let background = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGradient(
        starting: NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 1),
        ending: NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.06, alpha: 1)
    )?.draw(in: background, angle: -90)

    // The strip: a trapezoid narrowing towards the top, like a runway seen from
    // the approach.
    let strip = NSBezierPath()
    strip.move(to: CGPoint(x: side * 0.34, y: side * 0.14))
    strip.line(to: CGPoint(x: side * 0.66, y: side * 0.14))
    strip.line(to: CGPoint(x: side * 0.565, y: side * 0.80))
    strip.line(to: CGPoint(x: side * 0.435, y: side * 0.80))
    strip.close()
    NSColor(calibratedWhite: 1, alpha: 0.13).setFill()
    strip.fill()

    // Centre-line dashes, fading with distance.
    let dashCount = 5
    for index in 0..<dashCount {
        let t = CGFloat(index) / CGFloat(dashCount)
        let y = side * (0.20 + t * 0.52)
        let width = side * (0.055 - t * 0.022)
        let height = side * (0.055 - t * 0.026)
        let dash = NSBezierPath(
            roundedRect: CGRect(x: side * 0.5 - width / 2, y: y, width: width, height: height),
            xRadius: width / 2, yRadius: width / 2
        )
        NSColor(calibratedWhite: 1, alpha: 0.30 + (1 - t) * 0.45).setFill()
        dash.fill()
    }

    // The live run: one green dot on the threshold.
    let dotSide = side * 0.19
    let dot = NSBezierPath(ovalIn: CGRect(
        x: side * 0.5 - dotSide / 2, y: side * 0.10, width: dotSide, height: dotSide
    ))
    NSColor(calibratedRed: 0.20, green: 0.82, blue: 0.42, alpha: 1).setFill()
    dot.fill()

    return image
}

let directory = URL(fileURLWithPath: "AppIcon.iconset")
try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

for (points, scale) in sizes {
    let pixels = CGFloat(points * scale)
    let image = drawIcon(side: pixels)
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
