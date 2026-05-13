#!/usr/bin/env swift
// Renders the DMG background image used during install (drag-to-Applications).
// Output: resources/dmg-background.png + dmg-background@2x.png

import AppKit
import Foundation

func renderBackground(width: CGFloat, height: CGFloat, scale: CGFloat) -> Data {
    let pixelW = width * scale
    let pixelH = height * scale
    let img = NSImage(size: NSSize(width: pixelW, height: pixelH))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: scale, y: scale)

    // Soft top-to-bottom gradient background.
    let top = NSColor(srgbRed: 0.97, green: 0.98, blue: 1.00, alpha: 1.0).cgColor
    let bot = NSColor(srgbRed: 0.90, green: 0.93, blue: 0.98, alpha: 1.0).cgColor
    if let grad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [top, bot] as CFArray,
        locations: [0.0, 1.0]
    ) {
        ctx.drawLinearGradient(
            grad,
            start: CGPoint(x: 0, y: height),
            end: CGPoint(x: 0, y: 0),
            options: []
        )
    }

    // Title text near the top.
    let title = "Install MacConnect"
    let titleAttr: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
        .foregroundColor: NSColor(srgbRed: 0.12, green: 0.16, blue: 0.32, alpha: 1.0)
    ]
    let titleSize = (title as NSString).size(withAttributes: titleAttr)
    (title as NSString).draw(
        at: NSPoint(x: (width - titleSize.width) / 2, y: height - 50),
        withAttributes: titleAttr
    )

    let subtitle = "Drag the MacConnect icon onto the Applications folder."
    let subtitleAttr: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .regular),
        .foregroundColor: NSColor(srgbRed: 0.35, green: 0.40, blue: 0.55, alpha: 1.0)
    ]
    let subSize = (subtitle as NSString).size(withAttributes: subtitleAttr)
    (subtitle as NSString).draw(
        at: NSPoint(x: (width - subSize.width) / 2, y: height - 82),
        withAttributes: subtitleAttr
    )

    // Arrow from app position to applications position.
    // The Finder window will pin the .app to the left and the Applications
    // alias to the right. Icon centers (in DMG-window coordinates, origin
    // bottom-left): app at (160, 190), apps at (380, 190). We draw the
    // arrow between them, leaving icon space clear.
    let arrowY: CGFloat = 195
    let startX: CGFloat = 215
    let endX: CGFloat = 325
    ctx.setStrokeColor(NSColor(srgbRed: 0.30, green: 0.45, blue: 0.85, alpha: 0.85).cgColor)
    ctx.setLineWidth(3)
    ctx.setLineCap(.round)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: startX, y: arrowY))
    ctx.addLine(to: CGPoint(x: endX, y: arrowY))
    ctx.strokePath()

    // Arrowhead.
    ctx.beginPath()
    ctx.move(to: CGPoint(x: endX, y: arrowY))
    ctx.addLine(to: CGPoint(x: endX - 12, y: arrowY + 8))
    ctx.move(to: CGPoint(x: endX, y: arrowY))
    ctx.addLine(to: CGPoint(x: endX - 12, y: arrowY - 8))
    ctx.strokePath()

    // Hint just below the arrow.
    let hint = "Then launch MacConnect from your Applications folder."
    let hintAttr: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor(srgbRed: 0.40, green: 0.45, blue: 0.60, alpha: 1.0)
    ]
    let hintSize = (hint as NSString).size(withAttributes: hintAttr)
    (hint as NSString).draw(
        at: NSPoint(x: (width - hintSize.width) / 2, y: 60),
        withAttributes: hintAttr
    )

    img.unlockFocus()

    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else {
        fatalError("PNG encode failed")
    }
    return png
}

let fm = FileManager.default
let resources = URL(fileURLWithPath: "resources", isDirectory: true)
try? fm.createDirectory(at: resources, withIntermediateDirectories: true)

let path1x = resources.appendingPathComponent("dmg-background.png")
let path2x = resources.appendingPathComponent("dmg-background@2x.png")

try renderBackground(width: 540, height: 380, scale: 1).write(to: path1x)
print("wrote \(path1x.path)")
try renderBackground(width: 540, height: 380, scale: 2).write(to: path2x)
print("wrote \(path2x.path)")
