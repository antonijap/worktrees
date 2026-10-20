// Puts a --snapshot render into a macOS window on a wallpaper, for the README hero.
// The window gets rounded corners, traffic lights, a hairline border and a large soft shadow.
// The wallpaper is drawn here, so it is ours: soft blurred colour blobs by default, or with
// --pixel a 16-bit style landscape (dithered sky, layered hills, clouds by day, stars by night) on a coarse grid scaled up without smoothing. Both are deterministic.
//
// Usage: swift scripts/make-hero.swift <snapshot.png> <out.png|out.jpg> [--dark] [--pixel|--card]
// --card (what the README hero and tour use) puts the window on a quiet light grey card with
// even padding, a soft shadow and corners rounded like the banner's, transparent outside them so
// it sits cleanly on GitHub's light and dark pages. The grey and the shadow are the same in
// light and dark. Always a PNG, so the corners keep their alpha.
// The snapshot is a 2x render, ideally 1280x860 (see CONTRIBUTING.md for the command). The
// output is 3200x2000 with the window about 80 percent of the width. A PNG over 3 MB is
// written as a JPEG next to it instead, and the path printed.
// `--background WxH <out.png> [--dark] [--horizon f] [--sky-to f]` writes the pixel landscape alone.
import AppKit
import CoreImage

let args = CommandLine.arguments

// `--background WxH <out.png> [--dark] [--horizon f] [--sky-to f] [--cell n] [--scene name]
// [--clear x0,y0,x1,y1]` (a starless area, as fractions from the top left) writes only the pixel
// landscape, for scripts/make-banner.swift.
if args.count >= 4, args[1] == "--background" {
    func number(_ flag: String) -> Double? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil } }
    let parts = args[2].split(separator: "x").compactMap { Double($0) }
    func text(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
    var clear: CGRect? = nil
    if let spec = text("--clear") {
        let c: [Double] = spec.split(separator: ",").compactMap { Double($0) }
        if c.count == 4 { clear = CGRect(x: c[0], y: c[1], width: c[2] - c[0], height: c[3] - c[1]) }
    }
    let cell: Int = number("--cell").map { Int($0) } ?? 8
    let image = pixelWallpaper(size: CGSize(width: parts[0], height: parts[1]), dark: args.contains("--dark"),
                               horizon: number("--horizon") ?? 0.632, skyTo: number("--sky-to"),
                               cell: cell, scene: text("--scene"), clear: clear)
    try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
    exit(0)
}

guard args.count >= 3, let shot = NSImage(contentsOfFile: args[1]),
      let shotRep = shot.representations.first as? NSBitmapImageRep else {
    FileHandle.standardError.write(Data("usage: swift scripts/make-hero.swift <snapshot.png> <out> [--dark]\n".utf8))
    exit(2)
}
let dark = args.contains("--dark")
let pixel = args.contains("--pixel")
let card = args.contains("--card")
var out = URL(fileURLWithPath: args[2])

// The window at its pixel size, scaled to 2560 wide if the snapshot is another size.
let pixels = CGSize(width: shotRep.pixelsWide, height: shotRep.pixelsHigh)
let scale = 2560 / pixels.width
let window = CGSize(width: 2560, height: (pixels.height * scale).rounded())
/// The card: grey, padding on every side (pixels at 2x, so 80pt) and the corner radius as the
/// banner's share of its width (24pt of 1280), since GitHub shows both at the column's width.
let cardGrey: UInt32 = 0xF0F0F2
let cardPadding: CGFloat = 160
let canvas = card
    ? CGSize(width: window.width + 2 * cardPadding, height: window.height + 2 * cardPadding)
    : CGSize(width: 3200, height: 2000)
let cardRadius = (canvas.width * 24 / 1280).rounded()
let origin = card
    ? CGPoint(x: cardPadding, y: cardPadding)
    : CGPoint(x: (canvas.width - window.width) / 2, y: (canvas.height - window.height) / 2 + 24)
let frame = CGRect(origin: origin, size: window)
// macOS 26 windows round their corners generously; 2x of about 20pt.
let radius: CGFloat = 40

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: Wallpaper

/// A calm field of large blurred blobs over a two-stop wash.
func wallpaper() -> CGImage {
    let ctx = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8,
                        bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let wash: [CGColor] = dark ? [color(0x0E1020), color(0x1A1430)] : [color(0xEEF1F8), color(0xF7EFEA)]
    let gradient = CGGradient(colorsSpace: space, colors: wash as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvas.height), end: CGPoint(x: canvas.width, y: 0), options: [])
    // (x, y as fractions of the canvas, radius as a fraction of the width, colour)
    let blobs: [(CGFloat, CGFloat, CGFloat, CGColor)] = dark ? [
        (0.12, 0.85, 0.42, color(0x2B3A8C, 0.85)),
        (0.88, 0.80, 0.38, color(0x4A2A7A, 0.80)),
        (0.70, 0.12, 0.45, color(0x0F5A6B, 0.75)),
        (0.20, 0.10, 0.35, color(0x3A1F55, 0.70)),
        (0.50, 0.55, 0.30, color(0x1C2A60, 0.60)),
    ] : [
        (0.10, 0.88, 0.42, color(0xBFD3FF, 0.90)),
        (0.90, 0.82, 0.38, color(0xE5D2FF, 0.85)),
        (0.75, 0.10, 0.45, color(0xFFD9C7, 0.85)),
        (0.18, 0.12, 0.35, color(0xC9EEE4, 0.80)),
        (0.52, 0.58, 0.30, color(0xF4F0FF, 0.70)),
    ]
    for (x, y, r, c) in blobs {
        let center = CGPoint(x: x * canvas.width, y: y * canvas.height)
        let clear = c.copy(alpha: 0)!
        let g = CGGradient(colorsSpace: space, colors: [c, clear] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: r * canvas.width, options: [])
    }
    let raw = ctx.makeImage()!
    // Blur it smooth, then a whisper of grain so the gradients don't band.
    let ci = CIImage(cgImage: raw)
    let blurred = ci.clampedToExtent().applyingGaussianBlur(sigma: 60).cropped(to: ci.extent)
    let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: ci.extent)
        .applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: dark ? 0.035 : 0.025),
            "inputBiasVector": CIVector(x: dark ? 1 : 0, y: dark ? 1 : 0, z: dark ? 1 : 0, w: 0),
        ])
    let grained = noise.composited(over: blurred)
    return CIContext(options: [.workingColorSpace: space]).createCGImage(grained, from: ci.extent)!
}

// MARK: Pixel wallpaper

/// A small fixed-seed generator, so the scene is the same every run.
struct Seeded {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}

/// The colours of a landscape: eight sky steps from the top down, four hill layers back to
/// front (fill, rim), and stars or clouds.
struct Scene {
    let sky: [UInt32]
    let hills: [(fill: UInt32, rim: UInt32)]
    var stars: [UInt32]? = nil   // dim, mid, bright
    var clouds: (body: UInt32, shade: UInt32)? = nil
    var seed: UInt64

    static func named(_ name: String) -> Scene {
        switch name {
        case "dawn": Scene(sky: [0x8EA6DA, 0x9FA3DC, 0xB6A2D6, 0xD0A6CC, 0xE8AEBC, 0xF6B9A8, 0xFBC89C, 0xFDDBA6],
                           hills: [(0xB6A0CC, 0xC9B4DA), (0x93B9BC, 0xA9CBCB), (0x74A3A6, 0x8BB7B7), (0x568A8F, 0x6B9EA1)],
                           clouds: (0xFFF4EE, 0xF3D6D8), seed: 0x5EED_1167)
        case "ocean": Scene(sky: [0x050D1C, 0x081628, 0x0B2036, 0x0D2B44, 0x0F3752, 0x10465F, 0x12606E, 0x1A8C8C],
                            hills: [(0x0F3A44, 0x174C57), (0x0B2E33, 0x123F44), (0x082327, 0x0E3236), (0x05181B, 0x0A2528)],
                            stars: [0x3F6A86, 0x7FA9C4, 0xD2ECF6], seed: 0x5EED_0CEA)
        case "ember": Scene(sky: [0x160B1E, 0x24102A, 0x361433, 0x4C1938, 0x671F3A, 0x86293A, 0xAD3C35, 0xD8602E],
                            hills: [(0x3A1A2C, 0x4B2236), (0x2A1224, 0x371830), (0x1D0C1B, 0x281225), (0x120712, 0x1B0C1A)],
                            stars: [0x6A3E5C, 0xB08AA0, 0xF6E2D8], seed: 0x5EED_E3BE)
        case "mono": Scene(sky: [0x0B0B0E, 0x0F0F13, 0x131318, 0x17171D, 0x1B1B22, 0x201F28, 0x272432, 0x342B48],
                           hills: [(0x1C1C22, 0x26262D), (0x16161B, 0x1E1E24), (0x111115, 0x18181D), (0x0C0C0F, 0x131317)],
                           stars: [0x2C2C34, 0x4A4A55, 0x7A7A86], seed: 0x5EED_6A9E)
        case "aurora": Scene(sky: [0x060B14, 0x0A1520, 0x0D2230, 0x0E3438, 0x13483F, 0x1D5E4A, 0x2E6E5E, 0x4A6C82],
                             hills: [(0x15303A, 0x1D3F4A), (0x0F242C, 0x163039), (0x0A1A20, 0x10252C), (0x061116, 0x0B1A1F)],
                             stars: [0x2F5A5C, 0x7FBFAF, 0xE2FFF2], seed: 0x5EED_A0A0)
        default: Scene(sky: [0x0B0A24, 0x13113A, 0x1D1850, 0x2B1F66, 0x40247A, 0x5E2A86, 0x8A2F86, 0xB43C7E],
                       hills: [(0x2A2459, 0x3A3170), (0x1D3546, 0x284A5C), (0x152B37, 0x1F3E4B), (0x0D1D26, 0x15303C)],
                       stars: [0x8E86C8, 0xC9C2F0, 0xF4F0FF], seed: 0x5EED_0D4C)
        }
    }
}

/// A calm 16-bit style landscape, one art pixel to 8 screen pixels. The window covers the
/// middle, so the sky behind it stays plain and the hills, clouds and stars
/// sit where they show: the sides, the top and the bottom edge.
/// `horizon` is where the hills begin and `skyTo` where the sky's colour steps end, both as
/// fractions of the height; the defaults are the hero's. Other sizes (the banner) scale the
/// clouds, stars and hills to fit.
func pixelWallpaper(size: CGSize, dark: Bool, horizon horizonFraction: Double = 0.632, skyTo: Double? = nil, cell: Int = 8,
                    scene named: String? = nil, clear: CGRect? = nil) -> CGImage {
    let scene = Scene.named(named ?? (dark ? "night" : "dawn"))
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let w = Int(size.width) / cell, h = Int(size.height) / cell // 400 x 250 for the hero
    let sx = Double(w) / 400, sy = Double(h) / 250
    var px = [UInt32](repeating: 0, count: w * h)
    func rgba(_ hex: UInt32) -> UInt32 {
        // Stored as bytes R, G, B, A in memory (little-endian word A B G R).
        let r = (hex >> 16) & 0xff, g = (hex >> 8) & 0xff, b = hex & 0xff
        return 0xff00_0000 | (b << 16) | (g << 8) | r
    }
    func set(_ x: Int, _ y: Int, _ c: UInt32) { if x >= 0, x < w, y >= 0, y < h { px[y * w + x] = c } }
    let bayer: [[Double]] = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]].map { $0.map { ($0 + 0.5) / 16 } }
    var rng = Seeded(state: scene.seed)
    let sky = scene.sky
    let horizon = Int((Double(h) * horizonFraction).rounded())
    let skyEnd = skyTo.map { Int(Double(h) * $0) } ?? horizon
    // Hills sit in the band below the horizon, scaled to its depth (92 rows in the hero).
    let depth = Double(h - horizon) / 92
    // Sky: stepped bands with a 4x4 ordered dither across each step.
    for y in 0..<h {
        let t = min(1, Double(y) / Double(skyEnd)) * Double(sky.count - 1)
        let low = Int(t), frac = t - Double(low)
        for x in 0..<w {
            let pick = frac > bayer[y % 4][x % 4] ? min(low + 1, sky.count - 1) : low
            set(x, y, rgba(sky[pick]))
        }
    }

    // Stars (dark) or clouds (light), in the top strip and down the sides.
    if let stars = scene.stars {
        for _ in 0..<Int(260 * sx * sy) {
            let x = Int(rng.next() * Double(w)), y = Int(pow(rng.next(), 1.6) * Double(horizon - 30))
            let bright = rng.next()
            // No stars where `clear` asks for plain sky (text goes there); fractions, top-left origin.
            if let clear, clear.contains(CGPoint(x: (Double(x) + 0.5) / Double(w), y: (Double(y) + 0.5) / Double(h))) { continue }
            set(x, y, rgba(bright > 0.85 ? stars[2] : bright > 0.5 ? stars[1] : stars[0]))
            if bright > 0.97 { set(x - 1, y, rgba(stars[0])); set(x + 1, y, rgba(stars[0])); set(x, y - 1, rgba(stars[0])); set(x, y + 1, rgba(stars[0])) }
        }
    } else if let cloud = scene.clouds {
        let clouds: [(Int, Int, Int)] = [(14, 10, 26), (70, 6, 34), (300, 9, 30), (352, 30, 36), (6, 52, 24), (372, 74, 22), (220, 5, 24)]
        for (ox, oy, olen) in clouds {
            let cx = Int(Double(ox) * sx), cy = Int(Double(oy) * sy), len = Int(Double(olen) * sx)
            for row in 0..<4 {
                let inset = [6, 2, 0, 3][row]
                for x in (cx + inset)..<(cx + len - inset / 2) {
                    set(x, cy + row, rgba(row == 3 ? cloud.shade : cloud.body))
                }
            }
        }
    }

    // Hills, back to front: each a ridge from a few seeded sines, stepped to whole pixels,
    // with a one pixel lighter rim along the top.
    // Shapes: the night scene's back ridge sits two rows lower than the others' (as it always has).
    let shapes: [(offset: Int, amp: Double, freq: Double, sharp: Bool)] = scene.stars != nil
        ? [(-30, 26, 0.035, true), (2, 12, 0.020, false), (26, 10, 0.028, false), (56, 8, 0.040, false)]
        : [(-32, 26, 0.035, true), (0, 12, 0.020, false), (24, 10, 0.028, false), (54, 8, 0.040, false)]
    let layers = zip(shapes, scene.hills).map { (offset: $0.offset, amp: $0.amp, freq: $0.freq, fill: $1.fill, rim: $1.rim, sharp: $0.sharp) }
    var highest = h
    for layer in layers {
        let phases = (0..<3).map { _ in rng.next() * 2 * .pi }
        for x in 0..<w {
            let fx = Double(x)
            var v = sin(fx * layer.freq + phases[0]) + 0.5 * sin(fx * layer.freq * 2.3 + phases[1]) + 0.25 * sin(fx * layer.freq * 5.1 + phases[2])
            if layer.sharp { v = 1 - abs(v) * 1.2 } // peaks rather than rolls
            let top = horizon + Int((Double(layer.offset) * depth).rounded()) - Int((v * layer.amp * depth).rounded())
            guard top < h else { continue }
            highest = min(highest, top)
            for y in max(0, top)..<h { set(x, y, rgba(y == top ? layer.rim : layer.fill)) }
        }
    }

    if ProcessInfo.processInfo.environment["PRINT_HILLS"] != nil {
        FileHandle.standardError.write(Data("hills reach \(Double(h - highest) / Double(h)) of the height\n".utf8))
    }
    let provider = CGDataProvider(data: Data(bytes: px, count: px.count * 4) as CFData)!
    let small = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                        decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    // Up to full size with nearest neighbour: hard pixel edges.
    let big = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                        bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    big.interpolationQuality = .none
    big.draw(small, in: CGRect(origin: .zero, size: size))
    return big.makeImage()!
}

// MARK: Compose

let ctx = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8,
                    bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
if card {
    // Everything stays inside the card's rounded corners; outside them is transparent.
    ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: canvas), cornerWidth: cardRadius, cornerHeight: cardRadius, transform: nil))
    ctx.clip()
    ctx.setFillColor(color(cardGrey))
    ctx.fill(CGRect(origin: .zero, size: canvas))
} else {
    ctx.draw(pixel ? pixelWallpaper(size: canvas, dark: dark) : wallpaper(), in: CGRect(origin: .zero, size: canvas))
}

let shape = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Two shadows: a wide soft one and a close one that seats the window.
// On the card: a soft wide one and a faint close one, the same for light and dark, kept well
// inside the padding (the wide one reaches about 80 + 24 px below the window, of 160).
let shadows: [(CGFloat, CGFloat, Double)] = card
    ? [(80, -24, 0.14), (8, -2, 0.08)]
    : [(180, -60, dark ? 0.60 : 0.26), (28, -8, dark ? 0.45 : 0.14)]
for (blur, offset, alpha) in shadows {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: offset), blur: blur, color: color(0x000000, alpha))
    ctx.addPath(shape)
    ctx.setFillColor(color(dark ? 0x141519 : 0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
}

// The app, clipped to the window's corners.
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
ctx.interpolationQuality = .high
ctx.draw(shotRep.cgImage!, in: frame)
ctx.restoreGState()

// Traffic lights, where macOS puts them: 12pt across, 20pt apart, centred 16pt down.
let lights: [(UInt32, UInt32)] = [(0xFF5F57, 0xE0443E), (0xFEBC2E, 0xDEA123), (0x28C840, 0x1AAB29)]
for (index, (fill, rim)) in lights.enumerated() {
    let center = CGPoint(x: frame.minX + 40 + CGFloat(index) * 40, y: frame.maxY - 32)
    let dot = CGRect(x: center.x - 12, y: center.y - 12, width: 24, height: 24)
    ctx.setFillColor(color(fill))
    ctx.fillEllipse(in: dot)
    ctx.setStrokeColor(color(rim, 0.9))
    ctx.setLineWidth(1)
    ctx.strokeEllipse(in: dot.insetBy(dx: 0.5, dy: 0.5))
}

// A 0.5pt border: dark on light, a faint light edge on dark.
ctx.addPath(CGPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.setStrokeColor(dark ? color(0xFFFFFF, 0.16) : color(0x000000, 0.14))
ctx.setLineWidth(1)
ctx.strokePath()

// MARK: Write

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
var data = rep.representation(using: .png, properties: [:])!
if out.pathExtension.lowercased() == "jpg" || out.pathExtension.lowercased() == "jpeg" || (!card && data.count > 3_000_000) {
    data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])!
    out = out.deletingPathExtension().appendingPathExtension("jpg")
}
try! data.write(to: out)
print("\(out.path) \(Int(canvas.width))x\(Int(canvas.height)) \(data.count / 1024) KB")
