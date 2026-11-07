// Draws the DMG window background: drag-to-install arrow + how to allow the app on first launch.
// Usage: swift scripts/make-dmg-background.swift <outDir>   → background.png, background@2x.png
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/dmg")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let W: CGFloat = 660, H: CGFloat = 480

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, at p: CGPoint, width: CGFloat = 560,
          align: NSTextAlignment = .left) {
    let style = NSMutableParagraphStyle()
    style.alignment = align
    style.lineSpacing = 3
    NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                               .foregroundColor: color, .paragraphStyle: style])
        .draw(with: CGRect(x: p.x, y: p.y, width: width, height: 200), options: [.usesLineFragmentOrigin])
}

func draw() {
    // Coordinates below are top-left based (flipped context).
    NSGradient(colors: [rgb(0xFBFAFF), rgb(0xF1EFFA)])!.draw(in: CGRect(x: 0, y: 0, width: W, height: H), angle: 90)

    text("把 MDReader 拖到「应用程序」完成安装", 15, .semibold, rgb(0x2A2840), at: CGPoint(x: 0, y: 26), width: W, align: .center)
    text("Drag MDReader to Applications", 11, .regular, rgb(0x8A87A3), at: CGPoint(x: 0, y: 48), width: W, align: .center)

    // Arrow between the two icons (icons sit at x 170 / 490, y 150).
    let arrow = NSBezierPath()
    arrow.move(to: CGPoint(x: 262, y: 150))
    arrow.line(to: CGPoint(x: 386, y: 150))
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    rgb(0x6D5DF0, 0.85).setStroke()
    let dash: [CGFloat] = [1, 12]
    arrow.setLineDash(dash, count: 2, phase: 0)
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: CGPoint(x: 384, y: 136))
    head.line(to: CGPoint(x: 402, y: 150))
    head.line(to: CGPoint(x: 384, y: 164))
    head.lineWidth = 5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    // Guide card
    let card = CGRect(x: 28, y: 262, width: W - 56, height: 192)
    let path = NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14)
    rgb(0xFFFFFF).setFill()
    path.fill()
    rgb(0xDCD8EE).setStroke()
    path.lineWidth = 1
    path.stroke()

    text("首次打开被拦截？这样放行（只需一次）", 13.5, .semibold, rgb(0x2A2840), at: CGPoint(x: 50, y: 280))
    let steps = [
        ("1", "在「应用程序」里双击打开 MDReader，出现提示时点「完成」"),
        ("2", "打开「系统设置 › 隐私与安全性」，滚到底部，点「仍要打开」"),
        ("3", "或：按右侧「安装说明.txt」中的终端命令操作"),
    ]
    for (i, s) in steps.enumerated() {
        let y = 312 + CGFloat(i) * 34
        let badge = NSBezierPath(ovalIn: CGRect(x: 50, y: y, width: 20, height: 20))
        rgb(0x6D5DF0).setFill()
        badge.fill()
        text(s.0, 11.5, .bold, .white, at: CGPoint(x: 50, y: y + 2.5), width: 20, align: .center)
        text(s.1, 12.5, .regular, rgb(0x3B3954), at: CGPoint(x: 80, y: y + 1.5), width: 400)
    }
    text("Blocked on first launch? Open it once, then System Settings › Privacy & Security › Open Anyway.",
         10.5, .regular, rgb(0x8A87A3), at: CGPoint(x: 50, y: 418), width: 440)
}

for scale in [1, 2] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W) * scale, pixelsHigh: Int(H) * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    let cg = ctx.cgContext
    // rep.size is in points, so the context already maps points to pixels; only flip it.
    cg.translateBy(x: 0, y: H)
    cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "background.png" : "background@2x.png"
    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}
print("written \(out.path)/background.png")
