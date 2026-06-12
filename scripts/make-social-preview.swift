#!/usr/bin/swift
// Generates docs/social-preview.png (1280×640) for GitHub's repository
// social preview: icon + wordmark + tagline on the left, the README panel
// screenshot on the right, a soft audio-waveform strip along the bottom.
// Inputs: Resources/AppIcon.svg and docs/panel.png.
import AppKit

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let projectRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let docs = projectRoot.appendingPathComponent("docs")

guard let icon = NSImage(contentsOf: projectRoot.appendingPathComponent("Resources/AppIcon.svg")),
      let panel = NSImage(contentsOf: docs.appendingPathComponent("panel.png")) else {
    fatalError("Resources/AppIcon.svg and docs/panel.png are required")
}

let width = 1280, height = 640
let brandBlue = NSColor(srgbRed: 88 / 255, green: 160 / 255, blue: 255 / 255, alpha: 1)

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high

// Background gradient (dark, slightly blue-tinted to match the brand)
NSGradient(starting: NSColor(srgbRed: 0.137, green: 0.157, blue: 0.204, alpha: 1),
           ending: NSColor(srgbRed: 0.059, green: 0.071, blue: 0.102, alpha: 1))!
    .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

// Audio-waveform strip along the bottom (deterministic heights)
let barWidth: CGFloat = 6, barGap: CGFloat = 8
var x: CGFloat = 10
var i = 0
while x < CGFloat(width) - 10 {
    let h = 10 + 40 * abs(sin(Double(i) * 0.83)) * (0.4 + 0.6 * abs(sin(Double(i) * 0.211 + 1)))
    brandBlue.withAlphaComponent(0.30).setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: 24, width: barWidth, height: h),
                 xRadius: 3, yRadius: 3).fill()
    x += barWidth + barGap
    i += 1
}

// Panel screenshot, right side (window shadow baked in)
let panelScale = 0.85
let panelSize = NSSize(width: 732 * panelScale, height: 368 * panelScale)
let panelRect = NSRect(x: CGFloat(width) - panelSize.width - 56,
                       y: (CGFloat(height) - panelSize.height) / 2 + 10,
                       width: panelSize.width, height: panelSize.height)
panel.draw(in: panelRect, from: .zero, operation: .sourceOver, fraction: 1)

// Left column: icon, wordmark, accent, tagline
let columnCenter = (CGFloat(width) - panelSize.width - 56) / 2

let iconSide: CGFloat = 150
icon.draw(in: NSRect(x: columnCenter - iconSide / 2, y: 386,
                     width: iconSide, height: iconSide),
          from: .zero, operation: .sourceOver, fraction: 1)

let center = NSMutableParagraphStyle()
center.alignment = .center

let title = "MeetNote" as NSString
title.draw(in: NSRect(x: columnCenter - 280, y: 262, width: 560, height: 110),
           withAttributes: [
               .font: NSFont.systemFont(ofSize: 80, weight: .bold),
               .foregroundColor: NSColor.white,
               .paragraphStyle: center,
           ])

brandBlue.setFill()
NSBezierPath(roundedRect: NSRect(x: columnCenter - 70, y: 244, width: 140, height: 7),
             xRadius: 3.5, yRadius: 3.5).fill()

let tagline = "Privacy-first meeting notes for macOS —\nrecorded, transcribed, summarized locally" as NSString
tagline.draw(in: NSRect(x: columnCenter - 290, y: 132, width: 580, height: 92),
             withAttributes: [
                 .font: NSFont.systemFont(ofSize: 26, weight: .regular),
                 .foregroundColor: NSColor(srgbRed: 0.72, green: 0.74, blue: 0.78, alpha: 1),
                 .paragraphStyle: center,
             ])

NSGraphicsContext.restoreGraphicsState()
let out = docs.appendingPathComponent("social-preview.png")
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("Wrote \(out.path)")
