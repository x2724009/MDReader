import AppKit

/// Draws the first page of a Markdown document as a small "paper" image.
/// Used by the Quick Look thumbnail extension (Finder icons) and the app's test harness.
enum MarkdownThumbnail {

    // Virtual page (points). Everything is laid out here, then scaled to the target size.
    static let pageWidth: CGFloat = 600
    static let pageAspect: CGFloat = 0.78   // width / height, close to A4 (0.707) but a bit wider
    static var pageHeight: CGFloat { pageWidth / pageAspect }
    static let margin: CGFloat = 44

    /// Largest page-shaped size that fits in `maximum`.
    static func pageSize(fitting maximum: CGSize) -> CGSize {
        var w = maximum.width
        var h = w / pageAspect
        if h > maximum.height { h = maximum.height; w = h * pageAspect }
        return CGSize(width: floor(max(w, 1)), height: floor(max(h, 1)))
    }

    // MARK: - Block model

    enum Kind {
        case heading(Int)
        case paragraph
        case listItem(marker: String, level: Int, task: Bool?)
        case quote
        case code(lang: String)
        case table(rows: [[String]])
        case rule
        case image(alt: String)
    }

    struct Block {
        var kind: Kind
        var text: String
    }

    // MARK: - Parsing (lightweight, first ~150 lines only)

    static func parse(_ source: String, maxLines: Int = 220) -> [Block] {
        var lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        if lines.count > maxLines { lines = Array(lines.prefix(maxLines)) }

        var i = 0
        // Front matter
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" {
            if let end = lines.dropFirst().firstIndex(where: { ["---", "..."].contains($0.trimmingCharacters(in: .whitespaces)) }) {
                i = end + 1
            }
        }

        var blocks: [Block] = []
        var para: [String] = []

        func flush() {
            if !para.isEmpty {
                blocks.append(Block(kind: .paragraph, text: para.joined(separator: " ")))
                para.removeAll()
            }
        }

        while i < lines.count {
            let raw = lines[i]
            let t = raw.trimmingCharacters(in: .whitespaces)

            // Fenced code
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                flush()
                let fence = String(t.prefix(3))
                let lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                i += 1
                blocks.append(Block(kind: .code(lang: lang), text: code.prefix(18).joined(separator: "\n")))
                continue
            }

            if t.isEmpty { flush(); i += 1; continue }

            // Setext headings
            if !para.isEmpty, t.allSatisfy({ $0 == "=" }) {
                let text = para.joined(separator: " "); para.removeAll()
                blocks.append(Block(kind: .heading(1), text: text)); i += 1; continue
            }
            if !para.isEmpty, t.count >= 2, t.allSatisfy({ $0 == "-" }) {
                let text = para.joined(separator: " "); para.removeAll()
                blocks.append(Block(kind: .heading(2), text: text)); i += 1; continue
            }

            // ATX heading
            if t.hasPrefix("#") {
                let hashes = t.prefix(while: { $0 == "#" }).count
                let rest = t.dropFirst(hashes)
                if hashes <= 6, rest.isEmpty || rest.first == " " {
                    flush()
                    var text = rest.trimmingCharacters(in: .whitespaces)
                    while text.hasSuffix("#") { text.removeLast() }
                    blocks.append(Block(kind: .heading(hashes), text: text.trimmingCharacters(in: .whitespaces)))
                    i += 1; continue
                }
            }

            // Horizontal rule
            let compact = t.replacingOccurrences(of: " ", with: "")
            if compact.count >= 3, let c = compact.first, "-*_".contains(c), compact.allSatisfy({ $0 == c }) {
                flush(); blocks.append(Block(kind: .rule, text: "")); i += 1; continue
            }

            // Blockquote (merge consecutive lines)
            if t.hasPrefix(">") {
                flush()
                var q: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    guard l.hasPrefix(">") else { break }
                    var s = l.drop(while: { $0 == ">" || $0 == " " })
                    if s.hasPrefix("[!") { s = s.drop(while: { $0 != "]" }).dropFirst() } // GitHub alerts
                    if !s.isEmpty { q.append(String(s)) }
                    i += 1
                }
                blocks.append(Block(kind: .quote, text: q.joined(separator: " ")))
                continue
            }

            // Table
            if t.hasPrefix("|") || (t.contains("|") && i + 1 < lines.count && isTableSeparator(lines[i + 1])) {
                flush()
                var rows: [[String]] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    guard l.contains("|"), !l.isEmpty else { break }
                    if !isTableSeparator(l) { rows.append(splitRow(l)) }
                    i += 1
                    if rows.count >= 12 { break }
                }
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
                if !rows.isEmpty { blocks.append(Block(kind: .table(rows: rows), text: "")) }
                continue
            }

            // List item
            if let item = listItem(raw) {
                flush()
                blocks.append(item); i += 1; continue
            }

            // Standalone image
            if t.hasPrefix("!["), t.hasSuffix(")"), let close = t.firstIndex(of: "]") {
                flush()
                let alt = String(t[t.index(t.startIndex, offsetBy: 2)..<close])
                blocks.append(Block(kind: .image(alt: alt), text: "")); i += 1; continue
            }

            // HTML lines: keep inner text only
            if t.hasPrefix("<") {
                let stripped = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                if !stripped.isEmpty { para.append(stripped) }
                i += 1; continue
            }

            para.append(t)
            i += 1
        }
        flush()
        return blocks
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.contains(":") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    private static func splitRow(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        // Keep [[target|alias]] intact: shield its pipe while splitting.
        t = t.replacingOccurrences(of: #"\[\[([^\]|]*)\\?\|([^\]]*)\]\]"#, with: "[[$1\u{1}$2]]", options: .regularExpression)
        return t.components(separatedBy: "|").map {
            $0.replacingOccurrences(of: "\u{1}", with: "|").trimmingCharacters(in: .whitespaces)
        }
    }

    private static func listItem(_ raw: String) -> Block? {
        let indent = raw.prefix(while: { $0 == " " || $0 == "\t" })
            .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let t = raw.trimmingCharacters(in: .whitespaces)
        var marker: String
        var rest: Substring
        if let f = t.first, "-*+".contains(f), t.dropFirst().first == " " {
            marker = "•"
            rest = t.dropFirst(2)
        } else {
            let digits = t.prefix(while: { $0.isNumber })
            guard !digits.isEmpty, digits.count <= 4 else { return nil }
            let after = t.dropFirst(digits.count)
            guard let p = after.first, p == "." || p == ")", after.dropFirst().first == " " else { return nil }
            marker = digits + "."
            rest = after.dropFirst(2)
        }
        var task: Bool? = nil
        let r = rest.trimmingCharacters(in: .whitespaces)
        if r.hasPrefix("[ ] ") || r == "[ ]" { task = false; rest = Substring(r.dropFirst(3)) }
        else if r.lowercased().hasPrefix("[x] ") || r.lowercased() == "[x]" { task = true; rest = Substring(r.dropFirst(3)) }
        if task != nil { marker = "" }
        return Block(kind: .listItem(marker: marker, level: min(indent / 2, 4), task: task),
                     text: rest.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Styling

    private struct Palette {
        static let paper = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        static let border = NSColor(srgbRed: 0.82, green: 0.84, blue: 0.87, alpha: 1)
        static let text = NSColor(srgbRed: 0.12, green: 0.14, blue: 0.16, alpha: 1)
        static let muted = NSColor(srgbRed: 0.39, green: 0.42, blue: 0.46, alpha: 1)
        static let faint = NSColor(srgbRed: 0.88, green: 0.90, blue: 0.92, alpha: 1)
        static let codeBG = NSColor(srgbRed: 0.96, green: 0.965, blue: 0.975, alpha: 1)
        static let inlineCodeBG = NSColor(srgbRed: 0.90, green: 0.91, blue: 0.93, alpha: 1)
        static let link = NSColor(srgbRed: 0.04, green: 0.40, blue: 0.85, alpha: 1)
        static let accent = NSColor(srgbRed: 0.36, green: 0.36, blue: 0.84, alpha: 1)
        static let codeText = NSColor(srgbRed: 0.20, green: 0.23, blue: 0.28, alpha: 1)
    }

    private static func font(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    private static func mono(size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func italic(_ f: NSFont) -> NSFont {
        NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask)
    }

    private static func paragraphStyle(lineHeight: CGFloat) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = lineHeight
        p.lineBreakMode = .byWordWrapping
        return p
    }

    /// Inline markdown (bold/italic/code/links) → attributed string.
    static func inline(_ raw: String, font base: NSFont, color: NSColor, lineSpacing: CGFloat = 4) -> NSAttributedString {
        // Obsidian [[target|alias]] → alias, [[a/b]] → b, ==mark== → mark
        let text = raw
            .replacingOccurrences(of: #"!?\[\[[^\]|]*\\?\|([^\]]*)\]\]"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"!?\[\[(?:[^\]]*/)?([^\]/]*)\]\]"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"==(\S[^=]*?)=="#, with: "$1", options: .regularExpression)
        let out = NSMutableAttributedString()
        let style = paragraphStyle(lineHeight: lineSpacing)
        let opts = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)

        guard let parsed = try? AttributedString(markdown: text, options: opts) else {
            return NSAttributedString(string: text, attributes: [.font: base, .foregroundColor: color, .paragraphStyle: style])
        }
        for run in parsed.runs {
            let s = String(parsed[run.range].characters)
            var f = base
            var c = color
            var attrs: [NSAttributedString.Key: Any] = [.paragraphStyle: style]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) {
                    f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask)
                }
                if intent.contains(.emphasized) { f = italic(f) }
                if intent.contains(.code) {
                    f = mono(size: base.pointSize * 0.88)
                    c = Palette.codeText
                    attrs[.backgroundColor] = Palette.inlineCodeBG
                }
                if intent.contains(.strikethrough) {
                    attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    c = Palette.muted
                }
            }
            if run.link != nil { c = Palette.link }
            if run.imageURL != nil { c = Palette.muted }
            attrs[.font] = f
            attrs[.foregroundColor] = c
            out.append(NSAttributedString(string: s, attributes: attrs))
        }
        return out
    }

    // MARK: - Drawing

    /// Draws the page into the *current* NSGraphicsContext, filling `size` (origin bottom-left, unflipped).
    static func drawPage(markdown: String, size: CGSize) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }

        cg.saveGState()
        // Flip to top-left origin.
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)

        let scale = size.width / pageWidth
        cg.scaleBy(x: scale, y: scale)
        let page = CGRect(x: 0, y: 0, width: pageWidth, height: size.height / scale)

        // Paper
        Palette.paper.setFill()
        page.fill()
        cg.clip(to: page)

        drawContent(parse(markdown), in: page.insetBy(dx: margin, dy: margin * 0.9))

        // Hairline border (stays ~1px regardless of thumbnail size)
        Palette.border.setStroke()
        let border = NSBezierPath(rect: page.insetBy(dx: 0.5 / scale, dy: 0.5 / scale))
        border.lineWidth = 1 / scale
        border.stroke()

        NSGraphicsContext.restoreGraphicsState()
        cg.restoreGState()
    }

    private static func drawContent(_ blocks: [Block], in rect: CGRect) {
        let bodySize: CGFloat = 17
        var y = rect.minY
        let x = rect.minX
        let w = rect.width
        let bottom = rect.maxY

        if blocks.isEmpty {
            let s = NSAttributedString(string: "Empty document", attributes: [
                .font: font(size: bodySize), .foregroundColor: Palette.muted])
            s.draw(at: CGPoint(x: x, y: y))
            return
        }

        func draw(_ s: NSAttributedString, x dx: CGFloat = 0, width: CGFloat? = nil) -> CGFloat {
            let ww = width ?? (w - dx)
            let r = s.boundingRect(with: CGSize(width: ww, height: .greatestFiniteMagnitude),
                                   options: [.usesLineFragmentOrigin, .usesFontLeading])
            let h = min(ceil(r.height), bottom - y + 40)
            s.draw(with: CGRect(x: x + dx, y: y, width: ww, height: h),
                   options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
            return ceil(r.height)
        }

        var previous: Kind? = nil
        for block in blocks {
            if y > bottom { break }
            if case .listItem = previous {
                if case .listItem = block.kind {} else { y += 8 }
            }

            switch block.kind {
            case .heading(let level):
                let sizes: [CGFloat] = [34, 27, 22, 19, 17, 16]
                let size = sizes[min(level, 6) - 1]
                if previous != nil { y += level <= 2 ? 16 : 10 }
                let s = inline(block.text, font: font(size: size, weight: .bold), color: Palette.text, lineSpacing: 2)
                y += draw(s)
                if level <= 2 {
                    y += 7
                    Palette.faint.setFill()
                    CGRect(x: x, y: y, width: w, height: 1.5).fill()
                    y += 3
                }
                y += 10

            case .paragraph:
                y += draw(inline(block.text, font: font(size: bodySize), color: Palette.text, lineSpacing: 5))
                y += 14

            case .listItem(let marker, let level, let task):
                let indent = CGFloat(level) * 22 + 6
                let textX = indent + 22
                let f = font(size: bodySize)
                if let done = task {
                    let box = CGRect(x: x + indent + 1, y: y + 4, width: 14, height: 14)
                    let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
                    if done {
                        Palette.accent.setFill(); path.fill()
                        let check = NSBezierPath()
                        check.move(to: CGPoint(x: box.minX + 3, y: box.midY))
                        check.line(to: CGPoint(x: box.minX + 6, y: box.maxY - 3.5))
                        check.line(to: CGPoint(x: box.maxX - 3, y: box.minY + 3.5))
                        check.lineWidth = 2
                        NSColor.white.setStroke(); check.stroke()
                    } else {
                        Palette.muted.setStroke(); path.lineWidth = 1.4; path.stroke()
                    }
                } else {
                    let m = NSAttributedString(string: marker, attributes: [
                        .font: marker == "•" ? font(size: bodySize, weight: .bold) : f,
                        .foregroundColor: Palette.muted])
                    m.draw(at: CGPoint(x: x + indent, y: y))
                }
                let color = task == true ? Palette.muted : Palette.text
                y += draw(inline(block.text, font: f, color: color, lineSpacing: 4), x: textX)
                y += 7

            case .quote:
                let s = inline(block.text, font: font(size: bodySize), color: Palette.muted, lineSpacing: 5)
                let top = y
                y += draw(s, x: 20)
                Palette.faint.setFill()
                NSBezierPath(roundedRect: CGRect(x: x, y: top - 2, width: 4, height: y - top + 4), xRadius: 2, yRadius: 2).fill()
                y += 14

            case .code:
                let pad: CGFloat = 14
                let s = NSAttributedString(string: block.text.isEmpty ? " " : block.text, attributes: [
                    .font: mono(size: 13.5),
                    .foregroundColor: Palette.codeText,
                    .paragraphStyle: paragraphStyle(lineHeight: 3)])
                let r = s.boundingRect(with: CGSize(width: CGFloat(10_000), height: CGFloat.greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading])
                let h = min(ceil(r.height) + pad * 2, bottom - y + 20)
                let box = CGRect(x: x, y: y, width: w, height: h)
                Palette.codeBG.setFill()
                NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: box.insetBy(dx: pad, dy: 4)).addClip()
                s.draw(at: CGPoint(x: x + pad, y: y + pad))
                NSGraphicsContext.restoreGraphicsState()
                y += h + 16

            case .table(let rows):
                let cols = max(rows.map(\.count).max() ?? 1, 1)
                let colW = w / CGFloat(cols)
                let rowH: CGFloat = 30
                let tableTop = y
                for (ri, row) in rows.enumerated() {
                    if y > bottom { break }
                    if ri == 0 {
                        Palette.codeBG.setFill()
                        CGRect(x: x, y: y, width: w, height: rowH).fill()
                    }
                    for c in 0..<cols {
                        let cell = c < row.count ? row[c] : ""
                        let f = ri == 0 ? font(size: 14.5, weight: .semibold) : font(size: 14.5)
                        let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail
                        let s = NSMutableAttributedString(attributedString: inline(cell, font: f, color: Palette.text))
                        s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
                        s.draw(with: CGRect(x: x + CGFloat(c) * colW + 9, y: y + 6, width: colW - 18, height: rowH - 8),
                               options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                    }
                    y += rowH
                    Palette.faint.setFill()
                    CGRect(x: x, y: y - 1, width: w, height: 1).fill()
                }
                Palette.border.setStroke()
                let frame = NSBezierPath(rect: CGRect(x: x, y: tableTop, width: w, height: y - tableTop))
                frame.lineWidth = 1; frame.stroke()
                for c in 1..<cols {
                    let lx = x + CGFloat(c) * colW
                    let l = NSBezierPath(); l.move(to: CGPoint(x: lx, y: tableTop)); l.line(to: CGPoint(x: lx, y: y))
                    Palette.faint.setStroke(); l.lineWidth = 1; l.stroke()
                }
                y += 16

            case .rule:
                y += 8
                Palette.faint.setFill()
                CGRect(x: x, y: y, width: w, height: 2).fill()
                y += 18

            case .image(let alt):
                let h: CGFloat = 130
                let box = CGRect(x: x, y: y, width: w, height: h)
                Palette.codeBG.setFill()
                NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
                // simple "mountain" glyph
                let m = NSBezierPath()
                let cx = box.midX, cy = box.midY
                m.move(to: CGPoint(x: cx - 40, y: cy + 22))
                m.line(to: CGPoint(x: cx - 12, y: cy - 10))
                m.line(to: CGPoint(x: cx + 4, y: cy + 6))
                m.line(to: CGPoint(x: cx + 16, y: cy - 4))
                m.line(to: CGPoint(x: cx + 40, y: cy + 22))
                m.close()
                Palette.border.setFill(); m.fill()
                NSBezierPath(ovalIn: CGRect(x: cx + 14, y: cy - 30, width: 14, height: 14)).fill()
                if !alt.isEmpty {
                    let s = NSAttributedString(string: alt, attributes: [.font: font(size: 13), .foregroundColor: Palette.muted])
                    s.draw(at: CGPoint(x: x + 12, y: box.maxY - 24))
                }
                y += h + 16
            }
            previous = block.kind
        }
    }

    /// Renders to a bitmap (used by the CLI preview tool / tests).
    static func image(markdown: String, maximumSize: CGSize, scale: CGFloat = 2) -> NSBitmapImageRep? {
        let size = pageSize(fitting: maximumSize)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.scaleBy(x: scale, y: scale)
        drawPage(markdown: markdown, size: size)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
