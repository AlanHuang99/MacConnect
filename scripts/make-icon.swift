#!/usr/bin/env swift
// Renders a basic AppIcon.icns for MacConnect.
//
// Produces resources/AppIcon.iconset/* PNGs at the required sizes, then
// invokes iconutil(1) to compile them into resources/AppIcon.icns.
// Run from the repo root: ./scripts/make-icon.swift

import AppKit
import Foundation

func render(at size: CGFloat) -> Data {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    // Rounded square background with a vertical gradient.
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let radius = size * 0.225
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.clip()

    let top = NSColor(srgbRed: 0.18, green: 0.41, blue: 0.78, alpha: 1.0).cgColor
    let bot = NSColor(srgbRed: 0.10, green: 0.22, blue: 0.55, alpha: 1.0).cgColor
    if let grad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [top, bot] as CFArray,
        locations: [0.0, 1.0]
    ) {
        ctx.drawLinearGradient(
            grad,
            start: CGPoint(x: 0, y: size),
            end: CGPoint(x: 0, y: 0),
            options: []
        )
    }

    // Three concentric arcs evoking "broadcast", drawn from the lower-left.
    let center = CGPoint(x: size * 0.32, y: size * 0.35)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.92).cgColor)
    ctx.setLineCap(.round)
    let radii: [CGFloat] = [0.18, 0.30, 0.42]
    for r in radii {
        ctx.setLineWidth(size * 0.045)
        ctx.beginPath()
        ctx.addArc(
            center: center,
            radius: size * r,
            startAngle: -.pi / 4,
            endAngle: .pi / 4,
            clockwise: false
        )
        ctx.strokePath()
    }
    // Solid dot at the origin
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillEllipse(in: CGRect(
        x: center.x - size * 0.05,
        y: center.y - size * 0.05,
        width: size * 0.10,
        height: size * 0.10
    ))

    img.unlockFocus()

    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encode failed at size \(size)")
    }
    return png
}

let fm = FileManager.default
let resources = URL(fileURLWithPath: "resources", isDirectory: true)
let iconset = resources.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? fm.createDirectory(at: iconset, withIntermediateDirectories: true)

// macOS .iconset required sizes (1x and 2x for each base size).
let entries: [(String, CGFloat)] = [
    ("icon_16x16.png",       16),
    ("icon_16x16@2x.png",    32),
    ("icon_32x32.png",       32),
    ("icon_32x32@2x.png",    64),
    ("icon_128x128.png",    128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",    256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",    512),
    ("icon_512x512@2x.png", 1024),
]

for (name, size) in entries {
    let url = iconset.appendingPathComponent(name)
    try render(at: size).write(to: url)
    print("wrote \(url.path) (\(Int(size))px)")
}

// Compile to .icns
let icns = resources.appendingPathComponent("AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try task.run()
task.waitUntilExit()
if task.terminationStatus != 0 {
    fatalError("iconutil failed with exit code \(task.terminationStatus)")
}
print("wrote \(icns.path)")
