// Draws the app icon: a treemap, because that is what the app is.
import AppKit
import Foundation

let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
                      xRadius: size * 0.22, yRadius: size * 0.22)
NSGradient(colors: [NSColor(calibratedRed: 0.15, green: 0.18, blue: 0.24, alpha: 1),
                    NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.15, alpha: 1)])?
    .draw(in: bg, angle: 90)

// Colours mirror the categories used in the app.
let tiles: [(CGFloat, CGFloat, CGFloat, CGFloat, NSColor)] = [
    (0.00, 0.00, 0.56, 0.62, NSColor(calibratedRed: 0.55, green: 0.42, blue: 0.80, alpha: 1)),
    (0.56, 0.00, 0.44, 0.34, NSColor(calibratedRed: 0.20, green: 0.62, blue: 0.63, alpha: 1)),
    (0.56, 0.34, 0.44, 0.28, NSColor(calibratedRed: 0.82, green: 0.62, blue: 0.24, alpha: 1)),
    (0.00, 0.62, 0.33, 0.38, NSColor(calibratedRed: 0.30, green: 0.54, blue: 0.82, alpha: 1)),
    (0.33, 0.62, 0.30, 0.38, NSColor(calibratedRed: 0.36, green: 0.66, blue: 0.42, alpha: 1)),
    (0.63, 0.62, 0.37, 0.20, NSColor(calibratedRed: 0.85, green: 0.51, blue: 0.28, alpha: 1)),
    (0.63, 0.82, 0.37, 0.18, NSColor(calibratedRed: 0.84, green: 0.44, blue: 0.62, alpha: 1)),
]
let pad = size * 0.13, inner = size - pad * 2, gap = size * 0.016
for (x, y, w, h, color) in tiles {
    let r = NSRect(x: pad + x * inner + gap, y: pad + y * inner + gap,
                   width: w * inner - gap * 2, height: h * inner - gap * 2)
    let p = NSBezierPath(roundedRect: r, xRadius: size * 0.022, yRadius: size * 0.022)
    color.setFill(); p.fill()
    NSColor(white: 1, alpha: 0.16).setFill()
    NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2),
                 xRadius: size * 0.022, yRadius: size * 0.022).fill()
}
img.unlockFocus()

guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
