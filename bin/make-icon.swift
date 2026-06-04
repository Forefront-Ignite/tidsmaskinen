#!/usr/bin/env swift
// Renders the Tidsmaskinen segmented-clock app icon to Resources/AppIcon.png
// (1024×1024). make-app.sh turns that into AppIcon.icns. Run: swift bin/make-icon.swift
import AppKit

let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no ctx") }

// ---- rounded-rect background (Big Sur icon grid: ~824pt inset, big radius) ----
let inset = 100.0
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
bg.addClip()
let grad = NSGradient(colors: [
    NSColor(srgbRed: 0.97, green: 0.97, blue: 1.0, alpha: 1),
    NSColor(srgbRed: 0.90, green: 0.90, blue: 0.98, alpha: 1),
])!
grad.draw(in: rect, angle: -90)

// subtle top specular highlight
NSColor.white.withAlphaComponent(0.5).setFill()
NSBezierPath(roundedRect: CGRect(x: inset, y: size * 0.55, width: size - inset * 2, height: size * 0.45 - inset),
             xRadius: 185, yRadius: 185).fill()

// ---- segmented ring ----
let center = CGPoint(x: size / 2, y: size / 2)
let r = size * 0.30
let lw = size * 0.092
let gap = 22.0
let seg = 90.0 - gap
let arcColors = [
    NSColor(srgbRed: 0.545, green: 0.361, blue: 0.965, alpha: 1), // #8b5cf6
    NSColor(srgbRed: 0.063, green: 0.725, blue: 0.506, alpha: 1), // #10b981
    NSColor(srgbRed: 0.961, green: 0.620, blue: 0.043, alpha: 1), // #f59e0b
    NSColor(srgbRed: 0.388, green: 0.400, blue: 0.945, alpha: 1), // #6366f1
]
for i in 0..<4 {
    let start = Double(i) * 90.0 + gap / 2
    let path = NSBezierPath()
    path.appendArc(withCenter: center, radius: r, startAngle: start, endAngle: start + seg, clockwise: false)
    path.lineWidth = lw
    path.lineCapStyle = .round
    arcColors[i].setStroke()
    path.stroke()
}

// ---- clock hands + hub ----
let ink = NSColor(srgbRed: 0.106, green: 0.110, blue: 0.149, alpha: 1) // #1b1c26
let handW = size * 0.055
ink.setStroke()
let hour = NSBezierPath()
hour.move(to: center)
hour.line(to: CGPoint(x: center.x, y: center.y + r * 0.56)) // up
hour.lineWidth = handW; hour.lineCapStyle = .round; hour.stroke()
let minute = NSBezierPath()
minute.move(to: center)
minute.line(to: CGPoint(x: center.x + r * 0.40, y: center.y - r * 0.22)) // lower-right
minute.lineWidth = handW; minute.lineCapStyle = .round; minute.stroke()
let hub = size * 0.045
ink.setFill()
NSBezierPath(ovalIn: CGRect(x: center.x - hub, y: center.y - hub, width: hub * 2, height: hub * 2)).fill()

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("png fail") }
let out = FileManager.default.currentDirectoryPath + "/Resources/AppIcon.png"
try! png.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
