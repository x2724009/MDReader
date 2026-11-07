import Cocoa
import WebKit

final class ReaderWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSPopoverDelegate,
                                    WKNavigationDelegate, WKUIDelegate, NSMenuItemValidation {

    private var web: ReaderWeb!
    private var webView: WKWebView { web.webView }
    private var renderedOnce = false
    private var isEditing = false
    private var settingsObserver: NSObjectProtocol?
    private var titleBar: TitleBarView!
    private var lookPopover: NSPopover?

    /// Files created with ⌘N: open them straight into the editor.
    static var openInEditMode = Set<String>()
    /// Set before opening a document that must get its own window (⌘-click, "Open in New Window").
    static var forceNewWindow = false
    private var hasBeenShown = false
    private var tabBarObservation: NSKeyValueObservation?

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdx", "txt"]

    private var markdownDocument: MarkdownDocument? { document as? MarkdownDocument }

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 460, height: 320)
        // A slim title bar that blends into the page: same colour, no separator.
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unifiedCompact
        window.titleVisibility = .hidden
        window.backgroundColor = Settings.lastBackground
        window.appearance = Settings.appearance
        // We decide ourselves where a new document goes (see showWindow), so the system
        // doesn't depend on which window happens to be in front or on System Settings.
        window.tabbingMode = .automatic
        window.isReleasedWhenClosed = false
        window.animationBehavior = .documentWindow
        // Don't reopen last session's documents behind the one the user just double-clicked;
        // recent files are one click away on the start page.
        window.isRestorable = false
        self.init(window: window)
        shouldCascadeWindows = true
        window.setFrameAutosaveName("MDReaderWindow")
        if window.frame.origin == .zero { window.center() }
        window.delegate = self
        setUpWebView()
        setUpToolbar()
        setUpTitleBar()
        settingsObserver = NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.window?.appearance = Settings.appearance
            self.web.applySettings(animated: true)
            self.updateButtons()
        }
    }

    deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    override var document: AnyObject? {
        didSet {
            markdownDocument?.onExternalChange = { [weak self] in self?.render(keepScroll: true) }
            render(keepScroll: false)
        }
    }

    // MARK: - Setup

    private func setUpWebView() {
        web = ReaderWeb.take()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        let container = NSView()
        container.wantsLayer = true
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        window?.contentView = container
        web.onMessage = { [weak self] message in self?.handle(message) }
    }

    private func setUpToolbar() {
        let toolbar = NSToolbar(identifier: "ReaderToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    // MARK: - Rendering

    private func render(keepScroll: Bool) {
        guard web.isReady, let doc = markdownDocument else { return }
        let base = doc.fileURL?.absoluteString ?? ""
        web.call("return MDReader.render(md, base, keep)",
                 ["md": doc.text, "base": base, "keep": keepScroll && renderedOnce]) { [weak self] _ in
            guard let self else { return }
            self.renderedOnce = true
            if let path = doc.fileURL?.standardizedFileURL.path, Self.openInEditMode.remove(path) != nil {
                self.web.call("MDReader.setMode(true)")
            }
        }
    }

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "ready":
            render(keepScroll: false)
        case "edited":
            if let text = message["text"] as? String { markdownDocument?.applyEdit(text) }
        case "mode":
            isEditing = message["edit"] as? Bool ?? false
            updateEditItem()
        case "listDir":
            listDirectory(message["path"] as? String)
        case "openFile":
            if let path = message["path"] as? String {
                openFile(URL(fileURLWithPath: path), newWindow: message["newWindow"] as? Bool ?? false)
            }
        case "pinTOC":
            let value = message["value"] as? Bool ?? true
            if Settings.showTOC != value { Settings.showTOC = value }
        case "sidebarTab":
            if let tab = message["tab"] as? String { Settings.sidebarTab = tab }
        case "wikilink":
            openWikilink(path: message["path"] as? String ?? "", heading: message["heading"] as? String ?? "")
        case "chrome":
            if let hex = message["bg"] as? String, let color = NSColor(hex: hex) {
                Settings.lastBackground = color
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.3
                    window?.backgroundColor = color
                }
            }
        default:
            break
        }
    }

    // MARK: - Navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if url.isFileURL, url.path == ReaderWeb.indexURL.path { return decisionHandler(.allow) }
        decisionHandler(.cancel)
        open(url)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { open(url) }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        renderedOnce = false
        web.markNotReady()
        webView.loadFileURL(ReaderWeb.indexURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    /// Markdown files open in MDReader, everything else in the default app.
    private func open(_ url: URL) {
        if url.isFileURL {
            var fileURL = url
            if fileURL.fragment != nil, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                comps.fragment = nil
                fileURL = comps.url ?? url
            }
            if Self.markdownExtensions.contains(fileURL.pathExtension.lowercased()) {
                openMarkdown(fileURL, heading: nil)
                return
            }
        }
        NSWorkspace.shared.open(url)
    }

    private func openMarkdown(_ url: URL, heading: String?, newWindow: Bool = false) {
        if newWindow, NSDocumentController.shared.document(for: url) == nil { Self.forceNewWindow = true }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { doc, _, error in
            if let error { Self.forceNewWindow = false; NSApp.presentError(error); return }
            guard let heading, !heading.isEmpty,
                  let wc = doc?.windowControllers.first as? ReaderWindowController else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                wc.web.call("MDReader.scrollToHeading(h)", ["h": heading])
            }
        }
    }

    // MARK: - Files sidebar

    private func listDirectory(_ path: String?) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL
        let dir = (path.map { URL(fileURLWithPath: $0) }
                   ?? markdownDocument?.fileURL?.deletingLastPathComponent()
                   ?? home).standardizedFileURL
        let current = markdownDocument?.fileURL?.standardizedFileURL.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles])) ?? []
            var dirs: [[String: Any]] = [], files: [[String: Any]] = []
            for u in items {
                let v = try? u.resourceValues(forKeys: Set(keys))
                if v?.isDirectory == true && v?.isPackage != true {
                    dirs.append(["name": u.lastPathComponent, "path": u.path, "dir": true])
                } else if Self.markdownExtensions.contains(u.pathExtension.lowercased()) {
                    files.append(["name": u.lastPathComponent, "path": u.path, "dir": false,
                                  "current": u.standardizedFileURL.path == current])
                }
            }
            let byName: ([String: Any], [String: Any]) -> Bool = {
                ($0["name"] as! String).localizedStandardCompare($1["name"] as! String) == .orderedAscending
            }
            let entries = dirs.sorted(by: byName) + files.sorted(by: byName)

            // Breadcrumb from the home folder (or the volume root), collapsed when deep.
            var chain: [URL] = []
            var cursor = dir
            while true {
                chain.insert(cursor, at: 0)
                if cursor.path == home.path || cursor.path == "/" { break }
                let parent = cursor.deletingLastPathComponent()
                if parent.path == cursor.path { break }
                cursor = parent
            }
            var crumbs = chain.map { u -> [String: Any] in
                ["name": u.path == "/" ? "/" : (u.path == home.path ? "~" : u.lastPathComponent), "path": u.path]
            }
            if crumbs.count > 5 {
                let hidden = crumbs[crumbs.count - 4]
                crumbs = [crumbs[0], ["name": "…", "path": hidden["path"]!]] + Array(crumbs.suffix(3))
            }
            DispatchQueue.main.async {
                self?.web.call("MDReader.setFiles(d)", ["d": ["path": dir.path, "crumbs": crumbs, "entries": entries]])
            }
        }
    }

    /// Opens a file from the sidebar in this same window (⌘-click: new window/tab).
    private func openFile(_ url: URL, newWindow: Bool) {
        let dc = NSDocumentController.shared
        if let existing = dc.document(for: url) { existing.showWindows(); return }
        guard !newWindow, let old = markdownDocument else { openMarkdown(url, heading: nil, newWindow: newWindow); return }
        let swap = { [weak self] in
            guard let self else { return }
            do {
                let type = try dc.typeForContents(of: url)
                let doc = try dc.makeDocument(withContentsOf: url, ofType: type)
                dc.addDocument(doc)
                old.removeWindowController(self)
                doc.addWindowController(self)
                old.close()
                dc.noteNewRecentDocument(doc)
                self.synchronizeWindowTitleWithDocumentName()
                self.setDocumentEdited(false)
            } catch {
                NSApp.presentError(error)
            }
        }
        if old.hasUnautosavedChanges {
            old.autosave(withImplicitCancellability: false) { _ in DispatchQueue.main.async(execute: swap) }
        } else {
            swap()
        }
    }

    // MARK: - Wikilinks ([[note]], Obsidian style)

    private func openWikilink(path: String, heading: String) {
        guard let docURL = markdownDocument?.fileURL else { return }
        let dir = docURL.deletingLastPathComponent()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = Self.resolveWikilink(path, from: dir)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let found else {
                    NSSound.beep()
                    self.web.call("MDReader.toast(m)", ["m": L("Not found: ") + path])
                    return
                }
                if Self.markdownExtensions.contains(found.pathExtension.lowercased()) {
                    self.openMarkdown(found, heading: heading)
                } else {
                    NSWorkspace.shared.open(found)
                }
            }
        }
    }

    static func resolveWikilink(_ target: String, from dir: URL) -> URL? {
        let fm = FileManager.default
        let hasExt = !(target as NSString).pathExtension.isEmpty
        let names = hasExt ? [target] : [target + ".md", target]
        func existing(_ base: URL) -> URL? {
            for n in names {
                let u = base.appendingPathComponent(n)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue { return u }
            }
            return nil
        }
        if let u = existing(dir) { return u }

        // Find the vault root (folder holding .obsidian), else stay in the document folder.
        var root = dir
        var cursor = dir
        for _ in 0..<12 {
            if fm.fileExists(atPath: cursor.appendingPathComponent(".obsidian").path) { root = cursor; break }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
        }
        if let u = existing(root) { return u }

        // Search by file name inside the vault.
        let wanted = (names[0] as NSString).lastPathComponent.lowercased()
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var seen = 0
        for case let u as URL in e {
            seen += 1
            if seen > 30_000 { break }
            if u.lastPathComponent.lowercased() == wanted { return u }
        }
        return nil
    }

    // MARK: - Actions

    @objc func toggleEditMode(_ sender: Any?) {
        web.call("return MDReader.toggleMode()")
    }

    @objc func toggleTOC(_ sender: Any?) {
        if isEditing { web.call("MDReader.setMode(false)") }
        Settings.showTOC.toggle()
    }

    @objc func zoomInText(_ sender: Any?) { Settings.zoom = (Settings.zoom * 1.1 * 100).rounded() / 100 }
    @objc func zoomOutText(_ sender: Any?) { Settings.zoom = (Settings.zoom / 1.1 * 100).rounded() / 100 }
    @objc func resetTextZoom(_ sender: Any?) { Settings.zoom = 1 }

    @objc func setTheme(_ sender: NSMenuItem) {
        Settings.theme = Settings.Theme.allCases[max(0, min(sender.tag, 2))]
    }

    @objc func setStyle(_ sender: NSMenuItem) {
        Settings.style = Settings.Style.allCases[max(0, min(sender.tag, 3))]
    }

    @objc func findInPage(_ sender: Any?) { window?.makeFirstResponder(webView); web.call("MDReader.find()") }
    @objc func findNextInPage(_ sender: Any?) { web.call("MDReader.findNext()") }
    @objc func findPreviousInPage(_ sender: Any?) { web.call("MDReader.findPrevious()") }

    @objc func reloadDocument(_ sender: Any?) {
        markdownDocument?.reloadFromDisk()
        render(keepScroll: true)
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let url = markdownDocument?.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func openInExternalEditor(_ sender: Any?) {
        guard let url = markdownDocument?.fileURL else { return }
        let candidates = NSWorkspace.shared.urlsForApplications(toOpen: url)
            .filter { Bundle(url: $0)?.bundleIdentifier != Bundle.main.bundleIdentifier }
        let preferred = ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.sublimetext.4",
                         "abnerworks.Typora", "md.obsidian", "com.apple.TextEdit"]
        let app = preferred.lazy.compactMap { id in candidates.first { Bundle(url: $0)?.bundleIdentifier == id } }.first
            ?? candidates.first
        guard let app else { NSWorkspace.shared.open(url); return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func printDocument(_ sender: Any?) { runPrint(saveTo: nil) }

    @objc func exportPDF(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let name = markdownDocument?.fileURL?.deletingPathExtension().lastPathComponent ?? "Document"
        panel.nameFieldStringValue = name + ".pdf"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.runPrint(saveTo: url)
        }
    }

    private func runPrint(saveTo url: URL?) {
        guard let window else { return }
        let info = (markdownDocument?.printInfo ?? NSPrintInfo.shared).copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 36; info.rightMargin = 36
        if let url {
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        }
        let op = webView.printOperation(with: info)
        op.showsPrintPanel = url == nil
        op.showsProgressPanel = true
        op.view?.frame = webView.bounds
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(setTheme(_:)):
            item.state = Settings.Theme.allCases[max(0, min(item.tag, 2))] == Settings.theme ? .on : .off
        case #selector(setStyle(_:)):
            item.state = Settings.Style.allCases[max(0, min(item.tag, 3))] == Settings.style ? .on : .off
        case #selector(toggleTOC(_:)):
            item.title = Settings.showTOC && !isEditing ? L("Hide Table of Contents") : L("Show Table of Contents")
        case #selector(toggleEditMode(_:)):
            item.title = isEditing ? L("Done Editing") : L("Edit")
        case #selector(revealInFinder(_:)), #selector(openInExternalEditor(_:)):
            return markdownDocument?.fileURL != nil
        default:
            break
        }
        return true
    }

    // MARK: - Title bar

    /// The toolbar stays empty: it only gives the title bar a comfortable height.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [] }

    private func setUpTitleBar() {
        titleBar = TitleBarView(target: self)
        guard let titlebarView = window?.standardWindowButton(.closeButton)?.superview else { return }
        titlebarView.addSubview(titleBar)
        // Stay on the traffic-light row: when several documents share the window as tabs,
        // the tab bar appears below and must not push or cover these controls.
        let anchorY = window?.standardWindowButton(.closeButton)?.centerYAnchor ?? titlebarView.centerYAnchor
        NSLayoutConstraint.activate([
            titleBar.leadingAnchor.constraint(equalTo: titlebarView.leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: titlebarView.trailingAnchor),
            titleBar.centerYAnchor.constraint(equalTo: anchorY),
            titleBar.heightAnchor.constraint(equalToConstant: 32),
        ])
        updateButtons()
        observeTabBar()
    }

    private func updateButtons() {
        titleBar?.tocButton.isActive = Settings.showTOC && !isEditing
        titleBar?.editButton.isActive = isEditing
        titleBar?.editButton.toolTip = isEditing ? L("Back to Reading (⌘E)") : L("Edit (⌘E)")
    }

    private func updateEditItem() { updateButtons() }

    /// With a visible tab bar the tabs already name each file: hide our centred title then.
    private func observeTabBar() {
        tabBarObservation = window?.tabGroup?.observe(\.isTabBarVisible, options: [.initial, .new]) { [weak self] group, _ in
            DispatchQueue.main.async { self?.titleBar?.setTitleHidden(group.isTabBarVisible) }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) { observeTabBar() }

    // MARK: - One window, many tabs

    /// The first time a document window is shown, attach it as a tab of an existing
    /// document window (unless the user asked for separate windows).
    override func showWindow(_ sender: Any?) {
        defer { hasBeenShown = true }
        let forceNew = Self.forceNewWindow
        Self.forceNewWindow = false
        guard !hasBeenShown, let window, !window.isVisible, Settings.openInTabs, !forceNew,
              let host = Self.hostWindow(excluding: window) else {
            super.showWindow(sender)
            return
        }
        host.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The front-most visible document window (its tab group receives new documents).
    private static func hostWindow(excluding window: NSWindow) -> NSWindow? {
        NSApp.orderedWindows.first { w in
            w !== window && w.isVisible && !w.isMiniaturized && w.windowController is ReaderWindowController
        }
    }

    /// The tab bar's "+" opens files instead of creating empty "Untitled" documents.
    override func newWindowForTab(_ sender: Any?) {
        NSDocumentController.shared.openDocument(sender)
    }

    override func synchronizeWindowTitleWithDocumentName() {
        super.synchronizeWindowTitleWithDocumentName()
        let name = document?.displayName ?? window?.title ?? ""
        titleBar?.setTitle(name, path: (document as? NSDocument)?.fileURL?.path)
    }

    override func setDocumentEdited(_ dirtyFlag: Bool) {
        super.setDocumentEdited(dirtyFlag)
        titleBar?.setEdited(dirtyFlag)
    }

    @objc func showLookPanel(_ sender: Any?) {
        if let lookPopover, lookPopover.isShown { lookPopover.performClose(sender); return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = LookPanelController()
        popover.delegate = self
        lookPopover = popover
        let anchor = titleBar.lookButton
        anchor.isActive = true
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    func popoverDidClose(_ notification: Notification) {
        titleBar?.lookButton.isActive = false
        lookPopover = nil
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        web.detach()
        tabBarObservation = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { WelcomeWindowController.showIfIdle() }
    }
}

func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }
