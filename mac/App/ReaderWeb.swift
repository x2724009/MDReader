import Cocoa
import WebKit

/// A WKWebView with the reader page loaded. One spare instance is kept warm so a
/// newly opened document can render immediately instead of waiting for WebKit to boot.
final class ReaderWeb: NSObject, WKScriptMessageHandler {

    let webView: WKWebView
    private(set) var isReady = false
    private var queued: [[String: Any]] = []

    var onMessage: (([String: Any]) -> Void)? {
        didSet {
            guard let onMessage else { return }
            let pending = queued
            queued.removeAll()
            pending.forEach(onMessage)
        }
    }

    private static let processPool = WKProcessPool()
    static let indexURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web")!

    override init() {
        let config = WKWebViewConfiguration()
        config.processPool = Self.processPool
        config.suppressesIncrementalRendering = false
        let controller = WKUserContentController()
        config.userContentController = controller
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 760), configuration: config)
        super.init()
        controller.add(WeakHandler(self), name: "native")
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground")
        webView.autoresizingMask = [.width, .height]
        // Read access to "/" so images next to the document load.
        webView.loadFileURL(Self.indexURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if body["type"] as? String == "ready" {
            isReady = true
            applySettings(animated: false)
        }
        if let onMessage { onMessage(body) } else { queued.append(body) }
    }

    func applySettings(animated: Bool) {
        guard isReady else { return }
        call("MDReader.configure(s, a)", ["s": Settings.javaScriptValue, "a": animated])
    }

    func call(_ script: String, _ args: [String: Any] = [:], completion: ((Any?) -> Void)? = nil) {
        guard isReady else { return }
        webView.callAsyncJavaScript(script, arguments: args, in: nil, in: .page) { result in
            switch result {
            case .success(let value): completion?(value)
            case .failure(let error):
                NSLog("MDReader JS error: \(error)")
                completion?(nil)
            }
        }
    }

    /// The page is reloading (e.g. after a WebKit crash): wait for the next "ready".
    func markNotReady() { isReady = false }

    func detach() {
        onMessage = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "native")
    }

    // MARK: - Pool

    private static var spare: ReaderWeb?

    static func prewarm() {
        if spare == nil { spare = ReaderWeb() }
    }

    static func take() -> ReaderWeb {
        let web = spare ?? ReaderWeb()
        spare = nil
        // Refill shortly after, off the critical path of opening this window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { prewarm() }
        return web
    }
}

/// Avoids the retain cycle WKUserContentController creates with its handlers.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}
