import Cocoa
import WebKit
import UniformTypeIdentifiers

/// Start page shown when no document is open: open / new / recent files / drop to open.
final class WelcomeWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKScriptMessageHandler {

    static let shared = WelcomeWindowController()

    private var webView: WKWebView!
    private var isReady = false
    private var settingsObserver: NSObjectProtocol?

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Settings.lastBackground
        window.appearance = Settings.appearance
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.animationBehavior = .documentWindow
        window.title = "MDReader"
        window.center()
        self.init(window: window)
        window.delegate = self

        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(WeakMessageProxy(self), name: "native")
        config.userContentController = controller
        let web = WKWebView(frame: window.contentView!.bounds, configuration: config)
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        window.contentView?.addSubview(web)
        webView = web
        if let url = Bundle.main.url(forResource: "start", withExtension: "html", subdirectory: "web") {
            web.loadFileURL(url, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        }

        settingsObserver = NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.window?.appearance = Settings.appearance
            self?.pushSettings()
        }
    }

    // MARK: - Showing

    func present() {
        refreshRecents()
        guard let window else { return }
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Show the start page if no document window is left.
    static func showIfIdle() {
        DispatchQueue.main.async {
            let hasDocWindow = NSApp.windows.contains { $0.isVisible && $0.windowController is ReaderWindowController }
            if !hasDocWindow && NSDocumentController.shared.documents.isEmpty { shared.present() }
        }
    }

    static func dismiss() {
        guard shared.window?.isVisible == true else { return }
        shared.window?.orderOut(nil)
    }

    // MARK: - Page bridge

    private func pushSettings() {
        guard isReady else { return }
        webView.callAsyncJavaScript("MDStart.configure(s)", arguments: ["s": Settings.javaScriptValue], in: nil, in: .page)
    }

    func refreshRecents() {
        guard isReady else { return }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let items: [[String: Any]] = NSDocumentController.shared.recentDocumentURLs.compactMap { url in
            guard fm.fileExists(atPath: url.path) else { return nil }
            var dir = url.deletingLastPathComponent().path
            if dir.hasPrefix(home) { dir = "~" + dir.dropFirst(home.count) }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
                .timeIntervalSince1970 ?? 0
            return ["name": url.lastPathComponent, "dir": dir, "path": url.path, "modified": modified * 1000]
        }
        webView.callAsyncJavaScript("MDStart.setRecents(r)", arguments: ["r": items], in: nil, in: .page)
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        switch body["type"] as? String {
        case "ready":
            isReady = true
            pushSettings()
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            webView.callAsyncJavaScript("MDStart.setVersion(v)", arguments: ["v": version], in: nil, in: .page)
            refreshRecents()
        case "open":
            NSDocumentController.shared.openDocument(nil)
        case "new":
            (NSApp.delegate as? AppDelegate)?.newMarkdownFile(nil)
        case "openRecent":
            if let path = body["path"] as? String { Self.open(URL(fileURLWithPath: path)) }
        case "clearRecents":
            NSDocumentController.shared.clearRecentDocuments(nil)
            refreshRecents()
        case "chrome":
            if let hex = body["bg"] as? String, let color = NSColor(hex: hex) { window?.backgroundColor = color }
        default:
            break
        }
    }

    static func open(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
    }

    // Dropped files make WebKit navigate to them: open them as documents instead.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if url.isFileURL, url.lastPathComponent == "start.html" { return decisionHandler(.allow) }
        decisionHandler(.cancel)
        if url.isFileURL {
            if ReaderWindowController.markdownExtensions.contains(url.pathExtension.lowercased()) { Self.open(url) }
            else { NSSound.beep() }
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) { refreshRecents() }
}

/// Breaks the WKUserContentController → handler retain cycle.
private final class WeakMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}
