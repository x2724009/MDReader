// Renders README screenshots of the real web UI with WebKit (offscreen).
// Usage: swift scripts/screenshots.swift <outDir>
import AppKit
import WebKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/images", relativeTo: root)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let web = root.appendingPathComponent("shared/web")
let sample = (try? String(contentsOf: root.appendingPathComponent("samples/feature-tour.md"), encoding: .utf8)) ?? "# MDReader"
let obsidian = (try? String(contentsOf: root.appendingPathComponent("samples/obsidian-demo.md"), encoding: .utf8)) ?? ""

struct Shot {
    let name: String, page: String, script: String, dark: Bool
}

let jsMD = { (s: String) -> String in
    let data = try! JSONSerialization.data(withJSONObject: [s], options: [])
    return String(data: data, encoding: .utf8)!.dropFirst().dropLast().description
}

let shots: [Shot] = [
    Shot(name: "reader-light", page: "index.html",
         script: "MDReader.configure({style:'github',theme:'light',toc:true,lang:'zh'}); MDReader.render(\(jsMD(obsidian + "\n" + sample)), 'file:///x.md', false)", dark: false),
    Shot(name: "reader-dark", page: "index.html",
         script: "MDReader.configure({style:'nord',theme:'dark',toc:true,lang:'zh'}); MDReader.render(\(jsMD(sample)), 'file:///x.md', false); document.getElementById('preview-pane').scrollTop=520", dark: true),
    Shot(name: "editor", page: "index.html",
         script: "MDReader.configure({style:'notion',theme:'light',toc:false,lang:'zh'}); MDReader.render(\(jsMD(sample)), 'file:///x.md', false); MDReader.setMode(true)", dark: false),
    Shot(name: "academic", page: "index.html",
         script: "MDReader.configure({style:'academic',theme:'light',toc:false,lang:'zh'}); MDReader.render(\(jsMD(sample)), 'file:///x.md', false)", dark: false),
    Shot(name: "start", page: "start.html",
         script: "MDStart.configure({style:'github',theme:'light',lang:'zh'}); MDStart.setVersion('1.0.0'); var n=Date.now(); MDStart.setRecents([{name:'项目周报.md',dir:'~/Documents/Notes',path:'/a',modified:n-120000},{name:'读书笔记.md',dir:'~/Obsidian/Reading',path:'/b',modified:n-3*3600e3},{name:'README.md',dir:'~/Code/MDReader',path:'/c',modified:n-86400e3*1.5},{name:'会议纪要.md',dir:'~/Documents/Work',path:'/d',modified:n-86400e3*9}])", dark: false),
]

final class Runner: NSObject, WKNavigationDelegate {
    var queue: [Shot]
    var window: NSWindow!
    var webView: WKWebView!
    var current: Shot?

    init(_ shots: [Shot]) { queue = shots }

    func next() {
        guard !queue.isEmpty else { NSApp.terminate(nil); return }
        let shot = queue.removeFirst()
        current = shot
        let size = shot.page == "start.html" ? NSRect(x: 0, y: 0, width: 780, height: 480) : NSRect(x: 0, y: 0, width: 1200, height: 760)
        window = NSWindow(contentRect: size, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: shot.dark ? .darkAqua : .aqua)
        webView = WKWebView(frame: size)
        webView.navigationDelegate = self
        window.contentView = webView
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()
        webView.loadFileURL(web.appendingPathComponent(shot.page), allowingReadAccessTo: web)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let shot = current else { return }
        // Offscreen pages don't tick CSS animations: switch them off so shots show the final state.
        let noMotion = "var st=document.createElement('style');st.textContent='*,*::before,*::after{animation:none!important;transition:none!important}';document.head.appendChild(st);"
        webView.evaluateJavaScript(noMotion + shot.script) { _, error in
            if let error { print("JS error in \(shot.name): \(error)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { self.snap(shot) }
        }
    }

    func snap(_ shot: Shot) {
        let config = WKSnapshotConfiguration()
        webView.takeSnapshot(with: config) { image, error in
            if let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: out.appendingPathComponent("\(shot.name).png"))
                print("wrote \(shot.name).png")
            } else {
                print("snapshot failed: \(shot.name) \(String(describing: error))")
            }
            self.next()
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let runner = Runner(shots)
DispatchQueue.main.async { runner.next() }
app.run()
