import Cocoa

/// Popover for reading style, appearance and text size.
final class LookPanelController: NSViewController {

    private var cards: [StyleCard] = []
    private let appearanceControl = NSSegmentedControl()
    private let zoomLabel = NSButton(title: "100%", target: nil, action: nil)
    private let openModeControl = NSSegmentedControl()
    private var observer: NSObjectProtocol?

    override func loadView() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        // Styles: 2 × 2 preview cards
        root.addArrangedSubview(header(L("Style")))
        let grid = NSGridView()
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        cards = Settings.Style.allCases.map { style in StyleCard(style: style) { Settings.style = style } }
        stride(from: 0, to: cards.count, by: 2).forEach { i in
            grid.addRow(with: Array(cards[i..<min(i + 2, cards.count)]))
        }
        root.addArrangedSubview(grid)
        root.setCustomSpacing(16, after: grid)

        // Appearance
        root.addArrangedSubview(header(L("Appearance")))
        let items: [(String, String)] = [("circle.lefthalf.filled", L("Auto")), ("sun.max", L("Light")), ("moon", L("Dark"))]
        appearanceControl.segmentCount = items.count
        appearanceControl.trackingMode = .selectOne
        appearanceControl.segmentDistribution = .fillEqually
        for (i, item) in items.enumerated() {
            appearanceControl.setImage(NSImage(systemSymbolName: item.0, accessibilityDescription: item.1), forSegment: i)
            appearanceControl.setLabel(item.1, forSegment: i)
            appearanceControl.setImageScaling(.scaleProportionallyDown, forSegment: i)
        }
        appearanceControl.target = self
        appearanceControl.action = #selector(appearanceChanged(_:))
        appearanceControl.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(appearanceControl)
        appearanceControl.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
        root.setCustomSpacing(16, after: appearanceControl)

        // Text size
        let sizeRow = NSStackView()
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 4
        let label = header(L("Text Size"))
        let smaller = HoverButton(symbol: "textformat.size.smaller", tooltip: L("Zoom Out"), target: self, action: #selector(smaller(_:)))
        let larger = HoverButton(symbol: "textformat.size.larger", tooltip: L("Zoom In"), target: self, action: #selector(larger(_:)))
        zoomLabel.isBordered = false
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        zoomLabel.contentTintColor = .secondaryLabelColor
        zoomLabel.target = self
        zoomLabel.action = #selector(resetZoom(_:))
        zoomLabel.toolTip = L("Actual Size")
        zoomLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        [label, spacer, smaller, zoomLabel, larger].forEach { sizeRow.addArrangedSubview($0) }
        root.addArrangedSubview(sizeRow)
        sizeRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
        root.setCustomSpacing(16, after: sizeRow)

        // Open documents: tabs in one window / separate windows
        root.addArrangedSubview(header(L("Open Documents In")))
        let modes: [(String, String)] = [("square.stack", L("Tabs")), ("macwindow.on.rectangle", L("New Windows"))]
        openModeControl.segmentCount = modes.count
        openModeControl.trackingMode = .selectOne
        openModeControl.segmentDistribution = .fillEqually
        for (i, m) in modes.enumerated() {
            openModeControl.setImage(NSImage(systemSymbolName: m.0, accessibilityDescription: m.1), forSegment: i)
            openModeControl.setLabel(m.1, forSegment: i)
            openModeControl.setImageScaling(.scaleProportionallyDown, forSegment: i)
        }
        openModeControl.target = self
        openModeControl.action = #selector(openModeChanged(_:))
        openModeControl.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(openModeControl)
        openModeControl.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true

        root.widthAnchor.constraint(equalToConstant: 300).isActive = true
        view = root
        sync()
        observer = NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.sync()
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private func header(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .systemFont(ofSize: 11, weight: .semibold)
        f.textColor = .secondaryLabelColor
        return f
    }

    private func sync() {
        cards.forEach { $0.isSelected = $0.style == Settings.style }
        appearanceControl.selectedSegment = Settings.Theme.allCases.firstIndex(of: Settings.theme) ?? 0
        zoomLabel.title = "\(Int((Settings.zoom * 100).rounded()))%"
        openModeControl.selectedSegment = Settings.openInTabs ? 0 : 1
    }

    @objc private func appearanceChanged(_ sender: NSSegmentedControl) {
        Settings.theme = Settings.Theme.allCases[max(0, sender.selectedSegment)]
    }
    @objc private func openModeChanged(_ sender: NSSegmentedControl) { Settings.openInTabs = sender.selectedSegment == 0 }
    @objc private func smaller(_ sender: Any?) { Settings.zoom = (Settings.zoom / 1.1 * 100).rounded() / 100 }
    @objc private func larger(_ sender: Any?) { Settings.zoom = (Settings.zoom * 1.1 * 100).rounded() / 100 }
    @objc private func resetZoom(_ sender: Any?) { Settings.zoom = 1 }
}

/// A miniature page in a given style, used as a picker swatch.
final class StyleCard: NSView {

    let style: Settings.Style
    private let onPick: () -> Void
    var isSelected = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }

    private struct Swatch { let bg, fg, accent, line: NSColor }

    init(style: Settings.Style, onPick: @escaping () -> Void) {
        self.style = style
        self.onPick = onPick
        super.init(frame: NSRect(x: 0, y: 0, width: 128, height: 92))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 128).isActive = true
        heightAnchor.constraint(equalToConstant: 92).isActive = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityRole(.button)
        setAccessibilityLabel(name)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var name: String {
        switch style {
        case .github: return "GitHub"
        case .notion: return "Notion"
        case .academic: return L("Academic")
        case .nord: return "Nord"
        }
    }

    private var isDark: Bool {
        switch Settings.theme {
        case .dark: return true
        case .light: return false
        case .auto: return effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    private var swatch: Swatch {
        func c(_ hex: String) -> NSColor { NSColor(hex: hex) ?? .white }
        switch (style, isDark) {
        case (.github, false): return Swatch(bg: c("#ffffff"), fg: c("#1f2328"), accent: c("#0969da"), line: c("#d8dde3"))
        case (.github, true): return Swatch(bg: c("#17181b"), fg: c("#e4e6ea"), accent: c("#58a6ff"), line: c("#3a3d45"))
        case (.notion, false): return Swatch(bg: c("#ffffff"), fg: c("#37352f"), accent: c("#eb5757"), line: c("#e3e2e0"))
        case (.notion, true): return Swatch(bg: c("#191919"), fg: c("#d4d4d4"), accent: c("#ff7369"), line: c("#373737"))
        case (.academic, false): return Swatch(bg: c("#fbf9f4"), fg: c("#2b2a27"), accent: c("#8b2d2d"), line: c("#e2dac8"))
        case (.academic, true): return Swatch(bg: c("#1d1b18"), fg: c("#e3dccd"), accent: c("#d9a066"), line: c("#433e35"))
        case (.nord, false): return Swatch(bg: c("#eceff4"), fg: c("#2e3440"), accent: c("#5e81ac"), line: c("#d0d7e2"))
        case (.nord, true): return Swatch(bg: c("#2e3440"), fg: c("#d8dee9"), accent: c("#88c0d0"), line: c("#4c566a"))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let s = swatch
        let page = NSRect(x: 3, y: 22, width: bounds.width - 6, height: bounds.height - 25)

        // Selection ring / hover ring
        if isSelected || hovering {
            let ring = NSBezierPath(roundedRect: page.insetBy(dx: -2.5, dy: -2.5), xRadius: 11, yRadius: 11)
            ring.lineWidth = isSelected ? 2 : 1
            (isSelected ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
            ring.stroke()
        }

        let shape = NSBezierPath(roundedRect: page, xRadius: 9, yRadius: 9)
        s.bg.setFill()
        shape.fill()
        NSColor.separatorColor.setStroke()
        shape.lineWidth = 1
        shape.stroke()

        // "Aa" in the style's typeface
        let font: NSFont = style == .academic
            ? (NSFont(name: "Iowan Old Style Bold", size: 18) ?? .boldSystemFont(ofSize: 18))
            : .systemFont(ofSize: 18, weight: .bold)
        let aa = NSAttributedString(string: "Aa", attributes: [.font: font, .foregroundColor: style == .nord ? s.accent : s.fg])
        aa.draw(at: NSPoint(x: page.minX + 10, y: page.maxY - 30))

        // Text lines + accent
        s.accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: page.minX + 10, y: page.minY + 25, width: 22, height: 5), xRadius: 2.5, yRadius: 2.5).fill()
        s.line.setFill()
        NSBezierPath(roundedRect: NSRect(x: page.minX + 36, y: page.minY + 25, width: page.width - 48, height: 5), xRadius: 2.5, yRadius: 2.5).fill()
        NSBezierPath(roundedRect: NSRect(x: page.minX + 10, y: page.minY + 14, width: page.width - 34, height: 5), xRadius: 2.5, yRadius: 2.5).fill()

        // Name
        let label = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: isSelected ? .semibold : .regular),
            .foregroundColor: isSelected ? NSColor.controlAccentColor : NSColor.labelColor])
        let size = label.size()
        label.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: 2))
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPick() }
    }
    override func mouseDown(with event: NSEvent) {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
