// Renders the 1024×1024 application icon: usage `swift scripts/make-icon.swift out.png`
import AppKit

let size = 1024.0
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Background squircle with gradient.
let inset = 100.0
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let background = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(calibratedRed: 0.13, green: 0.36, blue: 0.86, alpha: 1),
                    NSColor(calibratedRed: 0.36, green: 0.20, blue: 0.75, alpha: 1)])!
    .draw(in: background, angle: -60)

// Network lines between three small monitors and the central one.
NSColor.white.withAlphaComponent(0.35).setStroke()
let center = NSPoint(x: size / 2, y: size / 2 + 40)
let nodes = [NSPoint(x: 260, y: 300), NSPoint(x: size / 2, y: 230), NSPoint(x: size - 260, y: 300)]
for n in nodes {
    let line = NSBezierPath()
    line.move(to: center)
    line.line(to: n)
    line.lineWidth = 14
    line.stroke()
}
NSColor.white.withAlphaComponent(0.9).setFill()
for n in nodes {
    NSBezierPath(ovalIn: NSRect(x: n.x - 34, y: n.y - 34, width: 68, height: 68)).fill()
}

// Central monitor glyph.
let config = NSImage.SymbolConfiguration(pointSize: 360, weight: .regular)
if let symbol = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let tinted = NSImage(size: symbol.size, flipped: false) { r in
        symbol.draw(in: r)
        NSColor.white.set()
        r.fill(using: .sourceAtop)
        return true
    }
    let s = tinted.size
    tinted.draw(in: NSRect(x: center.x - s.width / 2, y: center.y - s.height / 2 + 40, width: s.width, height: s.height))
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print(output)
