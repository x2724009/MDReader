// Draws three app-icon concepts and a comparison sheet.
// Usage: swift scripts/icon-options.swift <outDir>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "design")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func bitmap(_ px: Int, _ draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    ctx.cgContext.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
var squircle: NSBezierPath { NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186) }

func withShadow(_ color: NSColor, blur: CGFloat, y: CGFloat, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow()
    s.shadowColor = color
    s.shadowBlurRadius = blur
    s.shadowOffset = NSSize(width: 0, height: y)
    s.set()
    body()
    NSGraphicsContext.restoreGraphicsState()
}

func tileBase(_ top: NSColor, _ bottom: NSColor) {
    withShadow(rgb(0x000000, 0.30), blur: 26, y: -12) { bottom.setFill(); squircle.fill() }
    NSGradient(colors: [top, bottom])!.draw(in: squircle, angle: -90)
    // Soft top sheen + hairline rim for depth.
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [rgb(0xffffff, 0.22), rgb(0xffffff, 0)])!
        .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    rgb(0xffffff, 0.16).setStroke()
    let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 2, dy: 2), xRadius: 184, yRadius: 184)
    rim.lineWidth = 4
    rim.stroke()
}

func page(_ r: CGRect, fold: CGFloat, radius: CGFloat) -> NSBezierPath {
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

func fold(_ r: CGRect, _ f: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: CGPoint(x: r.maxX - f, y: r.maxY))
    p.line(to: CGPoint(x: r.maxX - f, y: r.maxY - f + 20))
    p.curve(to: CGPoint(x: r.maxX - f + 20, y: r.maxY - f),
            controlPoint1: CGPoint(x: r.maxX - f, y: r.maxY - f + 7), controlPoint2: CGPoint(x: r.maxX - f + 7, y: r.maxY - f))
    p.line(to: CGPoint(x: r.maxX, y: r.maxY - f))
    p.close()
    return p
}

func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: NSColor) {
    c.setFill()
    NSBezierPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), xRadius: h / 2, yRadius: h / 2).fill()
}

/// "M" + "↓" built from strokes, inside rect.
func markdownMark(_ r: CGRect, _ color: NSColor) {
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

// MARK: - A · 纸页 Paper — warm, calm, "a page you read"

func iconPaper() {
    tileBase(rgb(0xFBF6EC), rgb(0xEDE2CF))
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 512)
    ctx.rotate(by: -0.075)
    ctx.translateBy(x: -512, y: -512)
    let r = CGRect(x: 262, y: 188, width: 500, height: 648)
    withShadow(rgb(0x5A4A2C, 0.28), blur: 34, y: -16) { rgb(0xFFFFFF).setFill(); page(r, fold: 112, radius: 30).fill() }
    rgb(0xF1E8D8).setFill()
    fold(r, 112).fill()
    // Heading: coral "#" + ink bar
    let hash = NSAttributedString(string: "#", attributes: [
        .font: NSFont.systemFont(ofSize: 104, weight: .heavy), .foregroundColor: rgb(0xE5674A)])
    hash.draw(at: CGPoint(x: 316, y: 620))
    bar(398, 664, 214, 34, rgb(0x2B2A27))
    for (i, w) in [380.0, 330, 356, 250].enumerated() {
        bar(318, 548 - CGFloat(i) * 62, CGFloat(w), 22, rgb(0xD9D2C4))
    }
    bar(318, 290, 120, 22, rgb(0xE5674A, 0.55))
    ctx.restoreGState()
}

// MARK: - B · 字标 Monogram — bold, readable at 16 px

func iconMonogram() {
    tileBase(rgb(0x6D6AF8), rgb(0x4B2FC9))
    // Diagonal violet wash
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [rgb(0x9B5CF6, 0), rgb(0x9B5CF6, 0.55)])!.draw(in: tile, angle: -40)
    NSGraphicsContext.restoreGraphicsState()
    withShadow(rgb(0x1B0E5C, 0.45), blur: 22, y: -10) {
        markdownMark(CGRect(x: 236, y: 330, width: 552, height: 364), rgb(0xFFFFFF))
    }
    // Underline accent = "rendered" heading rule
    bar(236, 252, 552, 22, rgb(0xFFFFFF, 0.38))
}

// MARK: - C · 书签 Bookmark — night reading, a page held open

func iconBookmark() {
    tileBase(rgb(0x2A3550), rgb(0x121A2C))
    let r = CGRect(x: 250, y: 176, width: 524, height: 672)
    withShadow(rgb(0x000000, 0.45), blur: 36, y: -18) { rgb(0xF7F8FB).setFill(); page(r, fold: 0.001, radius: 34).fill() }
    // Text block
    let hash = NSAttributedString(string: "#", attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 92, weight: .bold), .foregroundColor: rgb(0x5B6CF0)])
    hash.draw(at: CGPoint(x: 302, y: 642))
    bar(372, 680, 190, 32, rgb(0x1E2638))
    for (i, w) in [400.0, 360, 410, 300, 350].enumerated() {
        bar(304, 590 - CGFloat(i) * 64, CGFloat(w), 22, rgb(0xD5DAE6))
    }
    // Ribbon bookmark
    let rb = NSBezierPath()
    let x0: CGFloat = 610, w: CGFloat = 96, top: CGFloat = 870, bottom: CGFloat = 596
    rb.move(to: CGPoint(x: x0, y: top))
    rb.line(to: CGPoint(x: x0 + w, y: top))
    rb.line(to: CGPoint(x: x0 + w, y: bottom))
    rb.line(to: CGPoint(x: x0 + w / 2, y: bottom + 46))
    rb.line(to: CGPoint(x: x0, y: bottom))
    rb.close()
    withShadow(rgb(0x000000, 0.30), blur: 12, y: -6) {
        NSGradient(colors: [rgb(0xFF8A5B), rgb(0xF0533F)])!.draw(in: rb, angle: -90)
    }
}

// MARK: - Output

let concepts: [(String, String, () -> Void)] = [
    ("A", "纸页 Paper", iconPaper),
    ("B", "字标 Monogram", iconMonogram),
    ("C", "书签 Bookmark", iconBookmark),
]

for (id, _, draw) in concepts {
    try bitmap(1024, draw).representation(using: .png, properties: [:])!
        .write(to: out.appendingPathComponent("icon-\(id).png"))
}

// Comparison sheet: big icon + 128/64/32/16 on light and dark strips.
let W: CGFloat = 1500, H: CGFloat = 1260
let sheet = NSImage(size: NSSize(width: W, height: H))
sheet.lockFocus()
rgb(0xF4F4F6).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
let colW = W / 3
for (i, (id, name, draw)) in concepts.enumerated() {
    let x = CGFloat(i) * colW
    let big = NSImage(size: NSSize(width: 1024, height: 1024))
    big.addRepresentation(bitmap(1024, draw))
    big.draw(in: NSRect(x: x + 60, y: 640, width: 380, height: 380))
    let title = NSAttributedString(string: "\(id) · \(name)", attributes: [
        .font: NSFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: rgb(0x1F2328)])
    title.draw(at: NSPoint(x: x + 250 - title.size().width / 2, y: 1060))
    for (row, dark) in [false, true].enumerated() {
        let y = CGFloat(row == 0 ? 360 : 80)
        (dark ? rgb(0x1E1F24) : rgb(0xFFFFFF)).setFill()
        NSBezierPath(roundedRect: NSRect(x: x + 30, y: y, width: colW - 60, height: 240), xRadius: 22, yRadius: 22).fill()
        var cx = x + 56
        for s in [128, 64, 32, 16] {
            let img = NSImage(size: NSSize(width: s, height: s))
            img.addRepresentation(bitmap(s * 2, draw))
            img.draw(in: NSRect(x: cx, y: y + 120 - CGFloat(s) / 2, width: CGFloat(s), height: CGFloat(s)))
            cx += CGFloat(s) + 34
        }
    }
}
let hint = NSAttributedString(string: "上排：浅色背景  ·  下排：深色背景  ·  尺寸 128 / 64 / 32 / 16", attributes: [
    .font: NSFont.systemFont(ofSize: 24), .foregroundColor: rgb(0x6B7280)])
hint.draw(at: NSPoint(x: W / 2 - hint.size().width / 2, y: 26))
sheet.unlockFocus()
let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("icon-options.png"))
print("written to \(out.path)")
