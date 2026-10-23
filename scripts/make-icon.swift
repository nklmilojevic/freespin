// Renders Resources/AppIcon.icns: run `swift scripts/make-icon.swift` from the repo root.
import AppKit

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024

    func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }

    // macOS icon grid: 824 pt rounded square centred on a 1024 canvas.
    let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: c(0x000000, 0.35))
    ctx.addPath(tilePath); ctx.setFillColor(c(0x1E1E2E)); ctx.fillPath()
    ctx.restoreGState()

    // Background: Catppuccin Mocha base → crust with a mauve glow.
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let bg = CGGradient(colorsSpace: nil, colors: [c(0x313244), c(0x181825)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    let glow = CGGradient(colorsSpace: nil, colors: [c(0xCBA6F7, 0.45), c(0xCBA6F7, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512 * s, y: 600 * s), startRadius: 0,
                           endCenter: CGPoint(x: 512 * s, y: 600 * s), endRadius: 430 * s, options: [])
    ctx.restoreGState()

    // Smooth-scroll motion lines on the right.
    for (i, alpha) in [0.85, 0.55, 0.3].enumerated() {
        let x = (690 + CGFloat(i) * 46) * s
        let h = (230 - CGFloat(i) * 50) * s
        let line = CGPath(roundedRect: CGRect(x: x, y: 512 * s - h / 2 + 30 * s, width: 22 * s, height: h),
                          cornerWidth: 11 * s, cornerHeight: 11 * s, transform: nil)
        ctx.addPath(line); ctx.setFillColor(c(0x89B4FA, alpha)); ctx.fillPath()
    }

    // Mouse body.
    let body = CGRect(x: 342 * s, y: 250 * s, width: 300 * s, height: 470 * s)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 150 * s, cornerHeight: 150 * s, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * s), blur: 30 * s, color: c(0x11111B, 0.6))
    ctx.addPath(bodyPath); ctx.setFillColor(c(0xCBA6F7)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    let shade = CGGradient(colorsSpace: nil, colors: [c(0xE4D3FB), c(0xB48DEF)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(shade, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    // Button split.
    ctx.setStrokeColor(c(0x45475A, 0.55)); ctx.setLineWidth(10 * s)
    ctx.move(to: CGPoint(x: 492 * s, y: 720 * s)); ctx.addLine(to: CGPoint(x: 492 * s, y: 560 * s)); ctx.strokePath()
    ctx.move(to: CGPoint(x: 342 * s, y: 545 * s))
    ctx.addQuadCurve(to: CGPoint(x: 642 * s, y: 545 * s), control: CGPoint(x: 492 * s, y: 520 * s)); ctx.strokePath()
    ctx.restoreGState()

    // Scroll wheel.
    let wheel = CGRect(x: 467 * s, y: 585 * s, width: 50 * s, height: 105 * s)
    ctx.addPath(CGPath(roundedRect: wheel, cornerWidth: 25 * s, cornerHeight: 25 * s, transform: nil))
    ctx.setFillColor(c(0x1E1E2E)); ctx.fillPath()
    for k in 0..<4 {
        let y = (602 + CGFloat(k) * 21) * s
        ctx.addPath(CGPath(roundedRect: CGRect(x: 479 * s, y: y, width: 26 * s, height: 8 * s),
                           cornerWidth: 4 * s, cornerHeight: 4 * s, transform: nil))
        ctx.setFillColor(c(0x89B4FA, 0.9 - CGFloat(k) * 0.18)); ctx.fillPath()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(px).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
try! render(1024).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("Resources/AppIcon.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
print("wrote Resources/AppIcon.icns")
