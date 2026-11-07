// Generates AppIcon.icns and MarkdownDoc.icns (+ Windows .ico source PNGs).
// Usage: swift scripts/make-icons.swift <outDir>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icons")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func render(_ px: Int, _ draw: (CGFloat) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    let s = CGFloat(px) / 1024
    ctx.cgContext.scaleBy(x: s, y: s)
    draw(1024)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// A page with a folded top-right corner, in a 1024 canvas, unflipped coords.
func pagePath(_ r: CGRect, fold: CGFloat, radius: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: CGPoint(x: r.minX + radius, y: r.minY))
    p.line(to: CGPoint(x: r.maxX - radius, y: r.minY))
    p.appendArc(withCenter: CGPoint(x: r.maxX - radius, y: r.minY + radius), radius: radius, startAngle: 270, endAngle: 360)
    p.line(to: CGPoint(x: r.maxX, y: r.maxY - fold))
    p.line(to: CGPoint(x: r.maxX - fold, y: r.maxY))
    p.line(to: CGPoint(x: r.minX + radius, y: r.maxY))
    p.appendArc(withCenter: CGPoint(x: r.minX + radius, y: r.maxY - radius), radius: radius, startAngle: 90, endAngle: 180)
    p.line(to: CGPoint(x: r.minX, y: r.minY + radius))
    p.appendArc(withCenter: CGPoint(x: r.minX + radius, y: r.minY + radius), radius: radius, startAngle: 180, endAngle: 270)
    p.close()
    return p
}

func foldPath(_ r: CGRect, fold: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: CGPoint(x: r.maxX - fold, y: r.maxY))
    p.line(to: CGPoint(x: r.maxX - fold, y: r.maxY - fold + 18))
    p.curve(to: CGPoint(x: r.maxX - fold + 18, y: r.maxY - fold),
            controlPoint1: CGPoint(x: r.maxX - fold, y: r.maxY - fold + 6),
            controlPoint2: CGPoint(x: r.maxX - fold + 6, y: r.maxY - fold))
    p.line(to: CGPoint(x: r.maxX, y: r.maxY - fold))
    p.close()
    return p
}

/// Markdown mark: "M" + down arrow.
func drawMark(in r: CGRect, color: NSColor) {
    color.setFill()
    let w = r.width, h = r.height
    let stroke = w * 0.13
    let mW = w * 0.56
    let m = NSBezierPath()
    let x0 = r.minX, y0 = r.minY
    m.move(to: CGPoint(x: x0, y: y0))
    m.line(to: CGPoint(x: x0, y: y0 + h))
    m.line(to: CGPoint(x: x0 + stroke, y: y0 + h))
    m.line(to: CGPoint(x: x0 + mW / 2, y: y0 + h * 0.52))
    m.line(to: CGPoint(x: x0 + mW - stroke, y: y0 + h))
    m.line(to: CGPoint(x: x0 + mW, y: y0 + h))
    m.line(to: CGPoint(x: x0 + mW, y: y0))
    m.line(to: CGPoint(x: x0 + mW - stroke, y: y0))
    m.line(to: CGPoint(x: x0 + mW - stroke, y: y0 + h * 0.66))
    m.line(to: CGPoint(x: x0 + mW / 2, y: y0 + h * 0.24))
    m.line(to: CGPoint(x: x0 + stroke, y: y0 + h * 0.66))
    m.line(to: CGPoint(x: x0 + stroke, y: y0))
    m.close()
    m.fill()
    // Arrow
    let ax = x0 + mW + w * 0.1
    let aw = w - (ax - x0)
    let shaft = NSBezierPath(rect: CGRect(x: ax + aw / 2 - stroke / 2, y: y0 + h * 0.36, width: stroke, height: h * 0.64))
    shaft.fill()
    let head = NSBezierPath()
    head.move(to: CGPoint(x: ax, y: y0 + h * 0.42))
    head.line(to: CGPoint(x: ax + aw, y: y0 + h * 0.42))
    head.line(to: CGPoint(x: ax + aw / 2, y: y0))
    head.close()
    head.fill()
}

// MARK: App icon — concept B "Monogram"

func appIcon(_ px: Int) -> NSBitmapImageRep {
    render(px) { _ in
        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        let squircle = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = rgb(0x000000, 0.30)
        shadow.shadowBlurRadius = 26
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.set()
        rgb(0x4B2FC9).setFill()
        squircle.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGradient(colors: [rgb(0x6D6AF8), rgb(0x4B2FC9)])!.draw(in: squircle, angle: -90)
        NSGraphicsContext.saveGraphicsState()
        squircle.addClip()
        NSGradient(colors: [rgb(0x9B5CF6, 0), rgb(0x9B5CF6, 0.55)])!.draw(in: tile, angle: -40)
        NSGradient(colors: [rgb(0xffffff, 0.22), rgb(0xffffff, 0)])!
            .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        rgb(0xffffff, 0.16).setStroke()
        let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 2, dy: 2), xRadius: 184, yRadius: 184)
        rim.lineWidth = 4
        rim.stroke()

        NSGraphicsContext.saveGraphicsState()
        let ms = NSShadow()
        ms.shadowColor = rgb(0x1B0E5C, 0.45)
        ms.shadowBlurRadius = 22
        ms.shadowOffset = NSSize(width: 0, height: -10)
        ms.set()
        monogram(in: CGRect(x: 236, y: 330, width: 552, height: 364), color: .white)
        NSGraphicsContext.restoreGraphicsState()
        rgb(0xffffff, 0.38).setFill()
        NSBezierPath(roundedRect: CGRect(x: 236, y: 252, width: 552, height: 22), xRadius: 11, yRadius: 11).fill()
    }
}

/// Bold "M↓" used by the app icon.
func monogram(in r: CGRect, color: NSColor) {
    color.setFill()
    let w = r.width, h = r.height, s = w * 0.135
    let mW = w * 0.58
    let m = NSBezierPath()
    m.move(to: CGPoint(x: r.minX, y: r.minY))
    m.line(to: CGPoint(x: r.minX, y: r.maxY))
    m.line(to: CGPoint(x: r.minX + s * 1.05, y: r.maxY))
    m.line(to: CGPoint(x: r.minX + mW / 2, y: r.minY + h * 0.50))
    m.line(to: CGPoint(x: r.minX + mW - s * 1.05, y: r.maxY))
    m.line(to: CGPoint(x: r.minX + mW, y: r.maxY))
    m.line(to: CGPoint(x: r.minX + mW, y: r.minY))
    m.line(to: CGPoint(x: r.minX + mW - s, y: r.minY))
    m.line(to: CGPoint(x: r.minX + mW - s, y: r.minY + h * 0.64))
    m.line(to: CGPoint(x: r.minX + mW / 2, y: r.minY + h * 0.22))
    m.line(to: CGPoint(x: r.minX + s, y: r.minY + h * 0.64))
    m.line(to: CGPoint(x: r.minX + s, y: r.minY))
    m.close()
    m.fill()
    let ax = r.minX + mW + w * 0.09, aw = r.maxX - ax
    NSBezierPath(roundedRect: CGRect(x: ax + aw / 2 - s / 2, y: r.minY + h * 0.34, width: s, height: h * 0.66),
                 xRadius: s * 0.2, yRadius: s * 0.2).fill()
    let head = NSBezierPath()
    head.move(to: CGPoint(x: ax - s * 0.1, y: r.minY + h * 0.42))
    head.line(to: CGPoint(x: ax + aw + s * 0.1, y: r.minY + h * 0.42))
    head.line(to: CGPoint(x: ax + aw / 2, y: r.minY))
    head.close()
    head.fill()
}

// MARK: Document icon

func docIcon(_ px: Int) -> NSBitmapImageRep {
    render(px) { _ in
        let page = CGRect(x: 196, y: 64, width: 632, height: 896)
        NSGraphicsContext.saveGraphicsState()
        let s = NSShadow()
        s.shadowColor = rgb(0x000000, 0.22)
        s.shadowBlurRadius = 18
        s.shadowOffset = NSSize(width: 0, height: -6)
        s.set()
        rgb(0xFFFFFF).setFill()
        pagePath(page, fold: 170, radius: 28).fill()
        NSGraphicsContext.restoreGraphicsState()
        rgb(0xD6D9E0).setStroke()
        let border = pagePath(page.insetBy(dx: 2, dy: 2), fold: 168, radius: 26)
        border.lineWidth = 4
        border.stroke()
        rgb(0xE6E7F3).setFill()
        foldPath(page, fold: 170).fill()

        // Heading + lines
        rgb(0x2B2F36).setFill()
        NSBezierPath(roundedRect: CGRect(x: 280, y: 740, width: 300, height: 40), xRadius: 10, yRadius: 10).fill()
        rgb(0xDADDE3).setFill()
        let widths: [CGFloat] = [460, 400, 440, 300]
        for (i, w) in widths.enumerated() {
            NSBezierPath(roundedRect: CGRect(x: 280, y: 664 - CGFloat(i) * 52, width: w, height: 22),
                         xRadius: 11, yRadius: 11).fill()
        }

        // Badge
        let badge = CGRect(x: 280, y: 170, width: 464, height: 200)
        NSGradient(colors: [rgb(0x6D6AF8), rgb(0x4B2FC9)])!
            .draw(in: NSBezierPath(roundedRect: badge, xRadius: 40, yRadius: 40), angle: -90)
        drawMark(in: CGRect(x: 360, y: 210, width: 304, height: 120), color: .white)
    }
}

func writeIconset(name: String, _ make: (Int) -> NSBitmapImageRep) throws {
    let set = out.appendingPathComponent("\(name).iconset")
    try? FileManager.default.removeItem(at: set)
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = base * scale
            let file = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            try make(px).representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(file))
        }
    }
    // Windows .ico source sizes
    let win = out.appendingPathComponent("\(name)-win")
    try? FileManager.default.createDirectory(at: win, withIntermediateDirectories: true)
    for px in [16, 24, 32, 48, 64, 128, 256] {
        try make(px).representation(using: .png, properties: [:])!.write(to: win.appendingPathComponent("\(px).png"))
    }
}

try writeIconset(name: "AppIcon", appIcon)
try writeIconset(name: "MarkdownDoc", docIcon)
// PNG used by the start page.
try appIcon(256).representation(using: .png, properties: [:])!
    .write(to: out.appendingPathComponent("appicon-256.png"))
print("icons written to \(out.path)")
