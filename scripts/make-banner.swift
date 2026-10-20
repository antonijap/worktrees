// Draws the README banner (3840x1500, 1280x500 at 3x) and the social preview (2560x1280, 2:1)
// GitHub shows when the repo link is shared (upload it in the repo's Settings). Both are the
// ember scene by default: the README hero's pixel landscape (scripts/make-hero.swift --background, same
// palette and seed) with the icon, the name and a tagline over it.
//
// Usage: swift scripts/make-banner.swift <out-dir> [--icon <png>] [--scene night|dawn|ocean|ember|mono|aurora]
// The icon is a 3D render on a transparent background, docs/icon-3d.png by default (the
// tilted-back ember render from scripts/render-icon-3d.py, kept at 1024 so the banner can be made
// without Blender). It is cropped to where it isn't transparent and given a soft shadow.
//
// Type is Inter, installed on this Mac (rsms.me/inter, SIL Open Font Licence; the font files
// are not in the repo). Inter Display is used for the title when it is installed. Letter
// spacing follows Inter's dynamic metrics, per size in points: tracking in em is
// -0.0223 + 0.185 * e^(-0.1745 * size).
import AppKit

let args = CommandLine.arguments
let scripts = URL(fileURLWithPath: args[0]).deletingLastPathComponent()
let outDir = URL(fileURLWithPath: args[1])
let sceneName = args.firstIndex(of: "--scene").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "ember"
let iconPath = args.firstIndex(of: "--icon").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    ?? scripts.deletingLastPathComponent().appendingPathComponent("docs/icon-3d.png").path

/// The icon render cropped to where it isn't transparent.
let icon: CGImage = {
    let image = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: iconPath)))!.cgImage!
    let w = image.width, h = image.height
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var minX = w, minY = h, maxX = 0, maxY = 0
    for y in 0..<h { for x in 0..<w where p[(y * w + x) * 4 + 3] > 8 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
    return image.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!
}()

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

/// The first installed font of the names given, so a missing Inter is a clear error.
func font(_ names: [String], pixels: CGFloat) -> NSFont {
    for name in names { if let f = NSFont(name: name, size: pixels) { return f } }
    FileHandle.standardError.write(Data("Inter isn't installed (looked for \(names.joined(separator: ", "))). Get it from https://rsms.me/inter\n".utf8))
    exit(1)
}

/// Inter's dynamic tracking for a size given in canvas pixels, as a kern in pixels.
func tracking(pixels: CGFloat, scale: CGFloat) -> CGFloat {
    let points = pixels / scale
    return (-0.0223 + 0.185 * exp(-0.1745 * points)) * pixels
}

/// The hero's night landscape at this size, with the hills low and the sky's colour steps
/// running the full height, so the text sits on its calm middle.
/// `cell` is screen pixels per art pixel: 4 per point, so the art is the same size at any scale
/// and every art pixel is a whole number of screen pixels.
func landscape(width: CGFloat, height: CGFloat, cell: Int, clear: CGRect) -> NSImage {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("banner-landscape-\(sceneName)-\(Int(width))x\(Int(height)).png")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["swift", scripts.appendingPathComponent("make-hero.swift").path, "--background",
                         "\(Int(width))x\(Int(height))", out.path, "--horizon", "0.93", "--sky-to", "1", "--dark", "--cell", "\(cell)",
                         "--scene", sceneName,
                         "--clear", "\(clear.minX),\(clear.minY),\(clear.maxX),\(clear.maxY)"]
    try! process.run()
    process.waitUntilExit()
    return NSImage(contentsOf: out)!
}

/// Centred lines, `lineHeight` times the size apart, the block's middle at `centerY`.
func draw(_ lines: [String], font: NSFont, color: NSColor, centerY: CGFloat, width: CGFloat, scale: CGFloat, lineHeight: CGFloat = 1.3) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: tracking(pixels: font.pointSize, scale: scale)]
    let step = font.pointSize * lineHeight
    let top = centerY + step * CGFloat(lines.count - 1) / 2
    for (index, line) in lines.enumerated() {
        let string = NSAttributedString(string: line, attributes: attributes)
        let size = string.size()
        string.draw(at: NSPoint(x: (width - size.width) / 2, y: top - CGFloat(index) * step - size.height / 2))
    }
}

// Text colours per scene, each 4.5:1 or better on every sky step it can sit on (title on steps
// 2 to 6, tagline on 3 to 6): night 6.7 and 5.2, dawn 7.9 and 6.3, ocean 6.6 and 5.6,
// ember 5.6 and 4.6, mono 13.7 and 9.3, aurora 5.8 and 4.6.
let (titleColor, taglineColor): (NSColor, NSColor) = {
    switch sceneName {
    case "dawn": (color(0x15161C), color(0x2E2F38))
    case "ocean": (color(0xF3F6F8), color(0xD3E6EE))
    case "ember": (color(0xFFF4EC), color(0xF6DCCF))  // title drawn as a gradient, see below
    case "mono": (color(0xF3F3F6), color(0xC9CAD3))
    case "aurora": (color(0xF0FFF8), color(0xCFE6DE))
    default: (color(0xF3F3F6), color(0xD6D7E0))
    }
}()
/// Title gradient: warm white to pale amber on ember (the amber stop is 6.8:1 on the brightest
/// sky step under the title and 4.7:1 even one step brighter); the plain title colour elsewhere.
let titleTop = titleColor
let titleBottom = sceneName == "ember" ? color(0xFFDDB0) : titleColor

/// The title filled with a gentle top-to-bottom gradient (`titleTop` to `titleBottom`) for a
/// little depth. Both stops keep the title's contrast on every sky step behind it.
func drawTitle(_ text: String, font: NSFont, centerY: CGFloat, width: CGFloat, height: CGFloat, scale: CGFloat) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .kern: tracking(pixels: font.pointSize, scale: scale)]
    let string = NSAttributedString(string: text, attributes: attributes)
    let size = string.size()
    let origin = NSPoint(x: (width - size.width) / 2, y: centerY - size.height / 2)
    // The letters as a mask the size of the canvas.
    let maskRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: maskRep)
    string.draw(at: origin)
    NSGraphicsContext.restoreGraphicsState()
    let mask = maskRep.cgImage!
    let cg = NSGraphicsContext.current!.cgContext
    // Glyph box: from the descender line to the cap height, roughly where the ink is.
    let inkBottom = origin.y - font.descender, inkTop = inkBottom + font.capHeight
    cg.saveGState()
    cg.clip(to: CGRect(x: 0, y: 0, width: width, height: height), mask: mask)
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [titleTop.cgColor, titleBottom.cgColor] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: inkTop), end: CGPoint(x: 0, y: inkBottom), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    cg.restoreGState()
}

// Layout below is in points of a 1280x500 banner; `scale` is pixels per point.
for (name, scale, heightPoints) in [("banner.png", CGFloat(3), CGFloat(500)), ("social-preview.png", CGFloat(2), CGFloat(640))] {
    let width = 1280 * scale, height = heightPoints * scale
    let shift = (heightPoints - 500) / 2 * scale
    let titleFont = font(["InterDisplay-SemiBold", "Inter-SemiBold", "Inter-Display-SemiBold"], pixels: 60 * scale)
    let taglineFont = font(["Inter-Regular", "Inter"], pixels: 28 * scale)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // The README banner gets rounded corners (24pt), transparent outside them; the social
    // preview stays square, since link cards crop their own.
    if name == "banner.png" {
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: height), xRadius: 24 * scale, yRadius: 24 * scale).addClip()
    }

    NSGraphicsContext.current?.imageInterpolation = .none
    // No stars behind the words: the title and tagline block plus a margin, as fractions.
    let line2 = NSAttributedString(string: "for every git worktree. Written in Swift.",
                                   attributes: [.font: taglineFont, .kern: tracking(pixels: taglineFont.pointSize, scale: scale)]).size().width
    let textHalf = max(line2, titleFont.pointSize * 4.2) / 2 + 24 * scale
    let textTop = height - (224 * scale + shift + titleFont.pointSize * 0.75 + 16 * scale)
    let textBottom = height - (136 * scale + shift - taglineFont.pointSize * 1.3 - 16 * scale)
    let clear = CGRect(x: (width / 2 - textHalf) / width, y: textTop / height,
                       width: 2 * textHalf / width, height: (textBottom - textTop) / height)
    landscape(width: width, height: height, cell: Int(4 * scale), clear: clear).draw(in: NSRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.current?.imageInterpolation = .high

    // The icon, 150pt tall at its own proportions, with a wide faint shadow so it floats on
    // the sky rather than sitting on a dark patch.
    let iconHeight = 150 * scale
    let iconWidth = iconHeight * CGFloat(icon.width) / CGFloat(icon.height)
    let cg = NSGraphicsContext.current!.cgContext
    cg.saveGState()
    // Wide, faint and warm: a plum shadow rather than black, so it melts into the sky.
    cg.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 110 * scale,
                 color: CGColor(srgbRed: 0.16, green: 0.04, blue: 0.14, alpha: 0.30))
    cg.interpolationQuality = .high
    cg.draw(icon, in: CGRect(x: (width - iconWidth) / 2, y: 290 * scale + shift, width: iconWidth, height: iconHeight))
    cg.restoreGState()

    drawTitle("Worktrees", font: titleFont, centerY: 224 * scale + shift, width: width, height: height, scale: scale)
    draw(["A small, well designed Mac app", "for every git worktree. Written in Swift."],
         font: taglineFont, color: taglineColor, centerY: 136 * scale + shift, width: width, scale: scale)

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent(name))
    print("Wrote \(name)")
}
