// Draws the app icon at 1024px and writes it to the path given as the first argument.
// Run by scripts/bundle.sh, which turns it into an .icns.
// Glyphs are Octicons (MIT), the same set the app uses.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon_1024.png"

let branchSVG = #"<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><path d="M9.5 3.25a2.25 2.25 0 1 1 3 2.122V6A2.5 2.5 0 0 1 10 8.5H6a1 1 0 0 0-1 1v1.128a2.251 2.251 0 1 1-1.5 0V5.372a2.25 2.25 0 1 1 1.5 0v1.836A2.493 2.493 0 0 1 6 7h4a1 1 0 0 0 1-1v-.628A2.25 2.25 0 0 1 9.5 3.25Zm-6 0a.75.75 0 1 0 1.5 0 .75.75 0 0 0-1.5 0Zm8.25-.75a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5ZM4.25 12a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Z"/></svg>"#

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// Draws an SVG glyph filled with a single colour.
func drawGlyph(_ svg: String, in rect: NSRect, fill: NSColor) {
    let source = NSImage(data: Data(svg.utf8))!
    let tinted = NSImage(size: rect.size)
    tinted.lockFocus()
    source.draw(in: NSRect(origin: .zero, size: rect.size))
    fill.set()
    NSRect(origin: .zero, size: rect.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    tinted.draw(in: rect)
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Tile on the macOS icon grid: 824pt body, 100pt margin.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)

// Drop shadow.
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = color(0x000000, 0.30)
shadow.shadowBlurRadius = 30
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.set()
color(0x0B0C0E).setFill()
tilePath.fill()
NSGraphicsContext.restoreGraphicsState()

// Body: near black, almost flat. Only a faint lift at the top.
NSGradient(colors: [color(0x1A1B1F), color(0x101114)])!.draw(in: tilePath, angle: -90)

// Hairline inner edge, brighter on top like a lit bevel.
NSGraphicsContext.saveGraphicsState()
let edge = NSBezierPath(roundedRect: tile.insetBy(dx: 2.5, dy: 2.5), xRadius: 184, yRadius: 184)
edge.lineWidth = 5
edge.setClip()
NSGradient(colors: [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0.04)])!.draw(in: tile, angle: -90)
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
tilePath.addClip()
let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 2.5, dy: 2.5), xRadius: 184, yRadius: 184)
rim.lineWidth = 5
color(0xFFFFFF, 0.08).setStroke()
rim.stroke()
NSGraphicsContext.restoreGraphicsState()

/// The glyph filled with a vertical gradient, so it reads as a raised, lit object.
func drawGradientGlyph(_ svg: String, in rect: NSRect, top: NSColor, bottom: NSColor) {
    let source = NSImage(data: Data(svg.utf8))!
    let filled = NSImage(size: rect.size)
    filled.lockFocus()
    source.draw(in: NSRect(origin: .zero, size: rect.size))
    NSGraphicsContext.current?.compositingOperation = .sourceAtop
    NSGradient(colors: [top, bottom])!.draw(in: NSRect(origin: .zero, size: rect.size), angle: -90)
    filled.unlockFocus()
    filled.draw(in: rect)
}

let glyphRect = NSRect(x: 252, y: 252, width: 520, height: 520)

// Contact shadow: tight and dark, then a wide soft one for lift.
for (blur, offset, alpha) in [(6.0, -4.0, 0.45), (36.0, -18.0, 0.35)] {
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow()
    s.shadowColor = color(0x000000, alpha)
    s.shadowBlurRadius = blur
    s.shadowOffset = NSSize(width: 0, height: offset)
    s.set()
    drawGlyph(branchSVG, in: glyphRect, fill: color(0x101114))
    NSGraphicsContext.restoreGraphicsState()
}

// Face: near-white at the top falling to soft grey, plus a 3px highlight on the upper edges.
drawGradientGlyph(branchSVG, in: glyphRect.offsetBy(dx: 0, dy: 3), top: color(0xFFFFFF, 0.9), bottom: color(0xFFFFFF, 0))
drawGradientGlyph(branchSVG, in: glyphRect, top: color(0xFAFAFC), bottom: color(0xB4B7C2))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
