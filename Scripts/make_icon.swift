// make_icon.swift - draw Whisker's app icon and write it as an .icns.
//
// Usage (from the repository root, or through `make icon`):
//   Scripts/swiftw.sh Scripts/make_icon.swift [--keep-iconset]
//
// Output:
//   Resources/AppIcon.icns       the icon bundled into Whisker.app by Scripts/build_app.sh
//   docs/assets/icon-1024.png    full-size render for the README and the product site
//   Resources/AppIcon.iconset/   intermediate PNGs, deleted afterwards unless --keep-iconset
//
// The artwork is drawn with Core Graphics in a 1024-point design space and rendered separately at
// every size, so small sizes stay crisp: a computer mouse on a dusk-blue squircle, with whiskers
// sweeping out from its nose and its cord curling away like a tail. Fine details (the seam highlight,
// the wheel ridges, the lowest whiskers) are dropped below 64 pixels where they would only blur.

import AppKit

// MARK: - Colour helpers

func sRGB() -> CGColorSpace {
    CGColorSpace(name: CGColorSpace.sRGB)!
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: sRGB(),
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255,
            CGFloat((hex >> 8) & 0xFF) / 255,
            CGFloat(hex & 0xFF) / 255,
            alpha,
        ]
    )!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(
        colorsSpace: sRGB(),
        colors: stops.map(\.1) as CFArray,
        locations: stops.map(\.0)
    )!
}

// MARK: - Shapes

/// A superellipse ("squircle"), the continuous-corner outline macOS app icons use.
func squircle(in rect: CGRect, exponent n: CGFloat = 5, segments: Int = 720) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    for i in 0..<segments {
        let t = CGFloat(i) / CGFloat(segments) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * copysign(pow(abs(c), 2 / n), c)
        let y = rect.midY + b * copysign(pow(abs(s), 2 / n), s)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// The mouse body: a rounded shell, narrower at the top (the cable end) than at the palm.
func mouseBody(center: CGPoint, width w: CGFloat, height h: CGFloat) -> CGPath {
    let top = center.y + h / 2, bottom = center.y - h / 2
    let left = center.x - w / 2, right = center.x + w / 2
    let shoulder = w * 0.08
    let path = CGMutablePath()
    path.move(to: CGPoint(x: center.x, y: top))
    path.addCurve(
        to: CGPoint(x: right, y: center.y + h * 0.04),
        control1: CGPoint(x: center.x + w * 0.42 - shoulder, y: top),
        control2: CGPoint(x: right, y: center.y + h * 0.30)
    )
    path.addCurve(
        to: CGPoint(x: center.x, y: bottom),
        control1: CGPoint(x: right, y: center.y - h * 0.30),
        control2: CGPoint(x: center.x + w * 0.40, y: bottom)
    )
    path.addCurve(
        to: CGPoint(x: left, y: center.y + h * 0.04),
        control1: CGPoint(x: center.x - w * 0.40, y: bottom),
        control2: CGPoint(x: left, y: center.y - h * 0.30)
    )
    path.addCurve(
        to: CGPoint(x: center.x, y: top),
        control1: CGPoint(x: left, y: center.y + h * 0.30),
        control2: CGPoint(x: center.x - w * 0.42 + shoulder, y: top)
    )
    path.closeSubpath()
    return path
}

// MARK: - Artwork

/// Draws the icon into a context whose user space is 1024 x 1024 points, origin bottom-left.
func drawIcon(into ctx: CGContext, pixels: Int) {
    let fine = pixels >= 64
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = squircle(in: tile)

    // Drop shadow under the tile, as on the standard macOS icon grid.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x1B2A4A))
    ctx.fillPath()
    ctx.restoreGState()

    // Background: dusk blue to deep violet, with a soft glow behind the mouse.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, color(0x3B6FD8)), (0.55, color(0x2C3F9E)), (1, color(0x24195E))]),
        start: CGPoint(x: tile.midX, y: tile.maxY),
        end: CGPoint(x: tile.midX, y: tile.minY),
        options: []
    )
    ctx.drawRadialGradient(
        gradient([(0, color(0x8FB8FF, 0.45)), (1, color(0x8FB8FF, 0))]),
        startCenter: CGPoint(x: 512, y: 540), startRadius: 0,
        endCenter: CGPoint(x: 512, y: 540), endRadius: 380,
        options: []
    )
    // A faint sheen along the top edge.
    ctx.drawLinearGradient(
        gradient([(0, color(0xFFFFFF, 0.18)), (1, color(0xFFFFFF, 0))]),
        start: CGPoint(x: tile.midX, y: tile.maxY),
        end: CGPoint(x: tile.midX, y: tile.maxY - 220),
        options: []
    )
    ctx.restoreGState()

    // Whiskers: three gentle arcs on each side, drawn before the mouse so they tuck under its shell.
    let whiskers: [(start: CGPoint, control: CGPoint, end: CGPoint, width: CGFloat, alpha: CGFloat, fineOnly: Bool)] = [
        (CGPoint(x: 440, y: 652), CGPoint(x: 320, y: 700), CGPoint(x: 196, y: 742), 13, 0.95, false),
        (CGPoint(x: 440, y: 620), CGPoint(x: 300, y: 640), CGPoint(x: 176, y: 642), 13, 0.95, false),
        (CGPoint(x: 440, y: 588), CGPoint(x: 310, y: 580), CGPoint(x: 196, y: 544), 11, 0.8, true),
    ]
    ctx.saveGState()
    ctx.setLineCap(.round)
    for whisker in whiskers where fine || !whisker.fineOnly {
        for mirrored in [false, true] {
            func x(_ value: CGFloat) -> CGFloat { mirrored ? 1024 - value : value }
            ctx.beginPath()
            ctx.move(to: CGPoint(x: x(whisker.start.x), y: whisker.start.y))
            ctx.addQuadCurve(
                to: CGPoint(x: x(whisker.end.x), y: whisker.end.y),
                control: CGPoint(x: x(whisker.control.x), y: whisker.control.y)
            )
            ctx.setStrokeColor(color(0xF4F7FF, whisker.alpha))
            ctx.setLineWidth(fine ? whisker.width : whisker.width * 1.6)
            ctx.strokePath()
        }
    }
    ctx.restoreGState()

    // Tail: a cord curling away from the palm end.
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: 512, y: 300))
    ctx.addCurve(to: CGPoint(x: 700, y: 226), control1: CGPoint(x: 520, y: 180), control2: CGPoint(x: 640, y: 160))
    ctx.addQuadCurve(to: CGPoint(x: 760, y: 300), control: CGPoint(x: 750, y: 270))
    ctx.setStrokeColor(color(0xF4F7FF, 0.9))
    ctx.setLineWidth(fine ? 13 : 20)
    ctx.strokePath()
    ctx.restoreGState()

    // The mouse.
    let center = CGPoint(x: 512, y: 492)
    let body = mouseBody(center: center, width: 300, height: 440)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x0B0F2E, 0.45))
    ctx.addPath(body)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, color(0xFFFFFF)), (0.6, color(0xE9EEFB)), (1, color(0xC9D3EE))]),
        start: CGPoint(x: center.x - 120, y: center.y + 220),
        end: CGPoint(x: center.x + 150, y: center.y - 220),
        options: []
    )

    // Button seam: a centre line from the top down to the wheel, and a curve across the palm.
    let seamTop = center.y + 220
    let seamY = center.y + 20
    ctx.setLineCap(.round)
    ctx.setStrokeColor(color(0x8E9AC4))
    ctx.setLineWidth(fine ? 7 : 12)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: center.x, y: seamTop))
    ctx.addLine(to: CGPoint(x: center.x, y: seamY + 60))
    ctx.move(to: CGPoint(x: center.x - 160, y: seamY - 6))
    ctx.addQuadCurve(to: CGPoint(x: center.x + 160, y: seamY - 6), control: CGPoint(x: center.x, y: seamY + 26))
    ctx.strokePath()
    if fine {
        ctx.setStrokeColor(color(0xFFFFFF, 0.9))
        ctx.setLineWidth(3)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: center.x + 6, y: seamTop - 8))
        ctx.addLine(to: CGPoint(x: center.x + 6, y: seamY + 150))
        ctx.strokePath()
    }
    ctx.restoreGState()

    // Scroll wheel: an accent-coloured pill straddling the seam.
    let wheel = CGRect(x: center.x - 22, y: seamY + 58, width: 44, height: 96)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: wheel, cornerWidth: 22, cornerHeight: 22, transform: nil))
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, color(0xFF9B6A)), (1, color(0xF0567A))]),
        start: CGPoint(x: wheel.midX, y: wheel.maxY),
        end: CGPoint(x: wheel.midX, y: wheel.minY),
        options: []
    )
    if fine {
        ctx.setStrokeColor(color(0xFFFFFF, 0.35))
        ctx.setLineWidth(4)
        for i in 1...3 {
            let y = wheel.minY + wheel.height * CGFloat(i) / 4
            ctx.beginPath()
            ctx.move(to: CGPoint(x: wheel.minX + 8, y: y))
            ctx.addLine(to: CGPoint(x: wheel.maxX - 8, y: y))
            ctx.strokePath()
        }
    }
    ctx.restoreGState()

    // Thin outline so the shell reads against the glow at every size.
    ctx.addPath(body)
    ctx.setStrokeColor(color(0x1B2A4A, 0.25))
    ctx.setLineWidth(fine ? 4 : 8)
    ctx.strokePath()
}

// MARK: - Rendering

func renderPNG(pixels: Int) -> Data {
    guard let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: sRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("could not create a \(pixels)px bitmap") }
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(into: ctx, pixels: pixels)
    guard let image = ctx.makeImage() else { fail("could not render the \(pixels)px icon") }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: pixels, height: pixels)
    guard let png = rep.representation(using: .png, properties: [:]) else { fail("could not encode the \(pixels)px PNG") }
    return png
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func main() {
    let keepIconset = CommandLine.arguments.dropFirst().contains("--keep-iconset")
    let fm = FileManager.default
    let root = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
    guard fm.fileExists(atPath: root.appendingPathComponent("Package.swift").path) else {
        fail("run this from the repository root (where Package.swift is)")
    }
    let iconset = root.appendingPathComponent("Resources/AppIcon.iconset", isDirectory: true)
    let icns = root.appendingPathComponent("Resources/AppIcon.icns")
    let readme = root.appendingPathComponent("docs/assets/icon-1024.png")

    // Pixel size for every file iconutil expects in an .iconset.
    let files: [(name: String, pixels: Int)] = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ]

    do {
        try? fm.removeItem(at: iconset)
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        var cache: [Int: Data] = [:]
        for file in files {
            let png = cache[file.pixels] ?? renderPNG(pixels: file.pixels)
            cache[file.pixels] = png
            try png.write(to: iconset.appendingPathComponent(file.name))
        }
        try fm.createDirectory(at: readme.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (cache[1024] ?? renderPNG(pixels: 1024)).write(to: readme)
    } catch {
        fail("could not write the iconset: \(error)")
    }

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", "-o", icns.path, iconset.path]
    do {
        try iconutil.run()
    } catch {
        fail("could not run iconutil: \(error)")
    }
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else { fail("iconutil failed with status \(iconutil.terminationStatus)") }

    if !keepIconset { try? fm.removeItem(at: iconset) }
    print("Wrote \(icns.path.replacingOccurrences(of: root.path + "/", with: ""))")
    print("Wrote \(readme.path.replacingOccurrences(of: root.path + "/", with: ""))")
}

main()
