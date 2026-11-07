import Foundation
import JavaScriptCore
import QuickLookUI
import UniformTypeIdentifiers

/// Space-bar Quick Look preview: Markdown → HTML using the same JS renderer as the app.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let markdown = TextDecoding.decode(data)
        let html = try Self.renderHTML(markdown: markdown, title: url.lastPathComponent)

        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 900, height: 1100)) { reply in
            reply.stringEncoding = .utf8
            reply.title = url.lastPathComponent
            return Data(html.utf8)
        }
        return reply
    }

    enum RenderError: Error { case missingResource(String), script(String) }

    static func renderHTML(markdown: String, title: String) throws -> String {
        let bundle = Bundle(for: PreviewProvider.self)
        func resource(_ path: String) throws -> String {
            guard let url = bundle.resourceURL?.appendingPathComponent("web/" + path),
                  let s = try? String(contentsOf: url, encoding: .utf8) else {
                throw RenderError.missingResource(path)
            }
            return s
        }

        guard let ctx = JSContext() else { throw RenderError.script("JSContext unavailable") }
        var jsError: String?
        ctx.exceptionHandler = { _, value in jsError = value?.toString() }
        for file in ["vendor/marked.min.js", "vendor/highlight.min.js", "render-core.js"] {
            ctx.evaluateScript(try resource(file))
        }
        if let jsError { throw RenderError.script(jsError) }

        let toHTML = ctx.objectForKeyedSubscript("MDCore")?.objectForKeyedSubscript("toHTML")
        let result = toHTML?.call(withArguments: [markdown])
        if let jsError { throw RenderError.script(jsError) }
        let body = result?.objectForKeyedSubscript("html")?.toString() ?? ""

        let css = try resource("reader.css")
        let safeTitle = title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(safeTitle)</title>
        <style>\(css)
        .markdown-body { padding: 32px 40px 60px; }
        </style></head>
        <body><article class="markdown-body">\(body)</article></body></html>
        """
    }
}
