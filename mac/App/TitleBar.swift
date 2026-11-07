import Cocoa

/// Borderless icon button: quiet at rest, soft rounded fill on hover, accent when active.
final class HoverButton: NSButton {

    var isActive = false { didSet { refresh(animated: true) } }
    private var hovering = false { didSet { refresh(animated: true) } }
    private var pressed = false { didSet { refresh(animated: false) } }
    private var tracking: NSTrackingArea?

    init(symbol: String, size: CGFloat = 14, tooltip: String, target: AnyObject?, action: Selector?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 26))
        isBordered = false
        title = ""
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        setButtonType(.momentaryChange)
        self.target = target
        self.action = action
        toolTip = tooltip
        setAccessibilityLabel(tooltip)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 30).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        setSymbol(symbol, size: size)
        refresh(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ name: String, size: CGFloat = 14) {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        image = NSImage(systemSymbolName: name, accessibilityDescription: toolTip)?.withSymbolConfiguration(config)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        super.mouseDown(with: event)   // runs the tracking loop and sends the action
        pressed = false
        hovering = bounds.contains(convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh(animated: false)
    }

    private func refresh(animated: Bool) {
        var fill: NSColor = .clear
        if isActive { fill = NSColor.controlAccentColor.withAlphaComponent(pressed ? 0.24 : (hovering ? 0.18 : 0.13)) }
        else if pressed { fill = NSColor.labelColor.withAlphaComponent(0.13) }
        else if hovering { fill = NSColor.labelColor.withAlphaComponent(0.07) }
        contentTintColor = isActive ? .controlAccentColor : (hovering ? .labelColor : .secondaryLabelColor)

        var cg: CGColor = NSColor.clear.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { cg = fill.cgColor }
        guard let layer else { return }
        if animated {
            let anim = CABasicAnimation(keyPath: "backgroundColor")
            anim.fromValue = layer.presentation()?.backgroundColor ?? layer.backgroundColor
            anim.toValue = cg
            anim.duration = 0.16
            anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(anim, forKey: "bg")
        }
        layer.backgroundColor = cg
    }
}

/// The content of the title bar: sidebar toggle · centred document title · edit / style buttons.
/// Empty areas pass clicks through so the window can still be dragged and double-click-zoomed.
final class TitleBarView: NSView {

    let tocButton: HoverButton
    let editButton: HoverButton
    let lookButton: HoverButton
    private let titleLabel = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let titleStack: NSStackView

    init(target: AnyObject) {
        tocButton = HoverButton(symbol: "sidebar.left", tooltip: L("Contents"), target: target,
                                action: #selector(ReaderWindowController.toggleTOC(_:)))
        editButton = HoverButton(symbol: "square.and.pencil", tooltip: L("Edit (⌘E)"), target: target,
                                 action: #selector(ReaderWindowController.toggleEditMode(_:)))
        lookButton = HoverButton(symbol: "paintpalette", size: 14, tooltip: L("Style & Appearance"), target: target,
                                 action: #selector(ReaderWindowController.showLookPanel(_:)))

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
        dot.alphaValue = 0

        titleStack = NSStackView(views: [titleLabel, dot])
        titleStack.orientation = .horizontal
        titleStack.spacing = 6
        titleStack.alignment = .centerY

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let trailing = NSStackView(views: [editButton, lookButton])
        trailing.spacing = 4
        for v in [tocButton, titleStack, trailing] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            tocButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 88),
            tocButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleStack.leadingAnchor.constraint(greaterThanOrEqualTo: tocButton.trailingAnchor, constant: 12),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setTitle(_ title: String, path: String?) {
        titleLabel.stringValue = title
        titleLabel.toolTip = path
    }

    func setTitleHidden(_ hidden: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            titleStack.animator().alphaValue = hidden ? 0 : 1
        }
    }

    func setEdited(_ edited: Bool) {
        var cg: CGColor = NSColor.clear.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { cg = NSColor.secondaryLabelColor.cgColor }
        dot.layer?.backgroundColor = cg
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            dot.animator().alphaValue = edited ? 1 : 0
        }
    }

    override var mouseDownCanMoveWindow: Bool { true }

    /// Only the buttons take clicks; everything else belongs to the title bar.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is NSButton ? hit : nil
    }
}
