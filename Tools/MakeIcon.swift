#!/usr/bin/env swift
//
// Generates Resources/Perch.icns. Run from the repo root:
//
//     swift Tools/MakeIcon.swift
//
// The mark is the product itself: a light island hanging off the top edge with
// the amber "needs you" pulse and the activity bars, on graphite. Below 64px
// the bars are dropped and the pulse is centred, because at 16px the detail
// turns to mush and a single clear shape reads better than a faithful one.

import AppKit
import Foundation

let canvas: CGFloat = 1024
let margin: CGFloat = 100          // Apple's icon grid leaves the artwork inset
let plateRect = CGRect(x: margin, y: margin, width: canvas - margin * 2, height: canvas - margin * 2)

// MARK: - Shapes

/// Superellipse, the continuous-corner shape macOS icons use. A plain rounded
/// rect reads noticeably "off" next to system icons.
func squircle(_ rect: CGRect, n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * pow(abs(ct), 2 / n) * (ct < 0 ? -1 : 1)
        let y = cy + b * pow(abs(st), 2 / n) * (st < 0 ? -1 : 1)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// Square across the top so it merges with the plate edge, rounded underneath.
func island(_ rect: CGRect, radius r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + r))
    p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.minY),
                   control: CGPoint(x: rect.maxX, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
    p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + r),
                   control: CGPoint(x: rect.minX, y: rect.minY))
    p.closeSubpath()
    return p
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
               colors: colors as CFArray, locations: locations)!
}

// MARK: - Drawing

func draw(into ctx: CGContext, pixels: Int) {
    let scale = CGFloat(pixels) / canvas
    ctx.scaleBy(x: scale, y: scale)
    ctx.setShouldAntialias(true)

    let plate = squircle(plateRect)

    // Graphite body, lit from the top.
    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([rgb(44, 48, 58), rgb(22, 24, 30), rgb(9, 10, 13)], [0, 0.55, 1]),
        start: CGPoint(x: plateRect.midX, y: plateRect.maxY),
        end: CGPoint(x: plateRect.midX, y: plateRect.minY),
        options: [])

    // The island, open — flush with the top edge like the real notch, hanging
    // down into a panel. The expanded state is the hero UI, and it fills the
    // plate far better than the collapsed pill did.
    let islandWidth: CGFloat = 612
    let islandHeight: CGFloat = 486
    let islandRect = CGRect(x: (canvas - islandWidth) / 2,
                            y: plateRect.maxY - islandHeight,
                            width: islandWidth, height: islandHeight)
    ctx.saveGState()
    ctx.addPath(island(islandRect, radius: 104))
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([rgb(255, 255, 255), rgb(223, 229, 238)], [0, 1]),
        start: CGPoint(x: islandRect.midX, y: islandRect.maxY),
        end: CGPoint(x: islandRect.midX, y: islandRect.minY),
        options: [])

    let amber = rgb(255, 184, 64)
    let green = rgb(94, 214, 143)
    let ink = rgb(18, 20, 25)

    let headHeight: CGFloat = 148
    let headMidY = islandRect.maxY - headHeight / 2
    let inset: CGFloat = 62

    func bar(_ rect: CGRect, _ color: CGColor) {
        ctx.setFillColor(color)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height / 2,
                           cornerHeight: rect.height / 2, transform: nil))
        ctx.fillPath()
    }

    if pixels >= 64 {
        // Head: pulse on the left, activity bars on the right.
        ctx.setFillColor(amber)
        ctx.fillEllipse(in: CGRect(x: islandRect.minX + inset, y: headMidY - 29, width: 58, height: 58))

        ctx.setFillColor(ink)
        let heights: [CGFloat] = [38, 70, 52, 84]
        var x = islandRect.maxX - inset - (CGFloat(heights.count) * 20 + CGFloat(heights.count - 1) * 16)
        for h in heights {
            ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: headMidY - h / 2, width: 20, height: h),
                               cornerWidth: 10, cornerHeight: 10, transform: nil))
            ctx.fillPath()
            x += 36
        }

        // Two session rows below, staggered so it reads as a list.
        let rowWidths: [CGFloat] = [islandWidth - inset * 2, (islandWidth - inset * 2) * 0.68]
        let dots = [green, amber]
        for (i, width) in rowWidths.enumerated() {
            let y = islandRect.maxY - headHeight - 60 - CGFloat(i) * 128
            ctx.setFillColor(dots[i])
            ctx.fillEllipse(in: CGRect(x: islandRect.minX + inset, y: y - 22, width: 44, height: 44))
            bar(CGRect(x: islandRect.minX + inset + 68, y: y - 20,
                       width: width - 68, height: 40),
                CGColor(srgbRed: 0.07, green: 0.08, blue: 0.10, alpha: 0.16))
        }
    } else {
        // 16 and 32pt: one pulse and one row, both oversized. At this scale a
        // faithfully-proportioned dot is under three pixels and disappears.
        ctx.setFillColor(amber)
        ctx.fillEllipse(in: CGRect(x: islandRect.midX - 78, y: headMidY - 78, width: 156, height: 156))
        bar(CGRect(x: islandRect.minX + 96, y: islandRect.minY + 120,
                   width: islandWidth - 192, height: 96),
            CGColor(srgbRed: 0.07, green: 0.08, blue: 0.10, alpha: 0.26))
    }

    ctx.restoreGState()
    ctx.restoreGState()

    // Rim light so the plate separates from a dark wallpaper.
    ctx.addPath(plate)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14))
    ctx.setLineWidth(3)
    ctx.strokePath()
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gctx
    draw(into: gctx.cgContext, pixels: pixels)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// MARK: - Emit

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/Perch.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for v in variants {
    try png(pixels: v.pixels).write(to: iconset.appendingPathComponent("\(v.name).png"))
}

let output = root.appendingPathComponent("Resources/Perch.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}

// Keep the largest render around as a preview for READMEs and store pages.
try png(pixels: 1024).write(to: root.appendingPathComponent("Resources/icon-preview.png"))
print("wrote \(output.path)")
