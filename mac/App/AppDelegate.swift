import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = NSDocumentController.shared
        NSApp.mainMenu = MainMenu.build()
        NSWindow.allowsAutomaticWindowTabbing = true
        // Boot WebKit now so the first document opens without a cold start.
        ReaderWeb.prewarm()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched directly (not by opening a file): show the start page.
        _ = WelcomeWindowController.shared   // start loading the page right away
        let isDefaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        guard isDefaultLaunch else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if NSDocumentController.shared.documents.isEmpty { WelcomeWindowController.shared.present() }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WelcomeWindowController.shared.present() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc func showWelcome(_ sender: Any?) { WelcomeWindowController.shared.present() }

    /// ⌥⌘O: open files in a separate window (they become tabs of that new window).
    @objc func openInNewWindow(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ["md", "markdown", "mdown", "mkd", "txt"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls.filter { NSDocumentController.shared.document(for: $0) == nil }
        guard let first = urls.first else { panel.urls.first.map { WelcomeWindowController.open($0) }; return }
        ReaderWindowController.forceNewWindow = true
        NSDocumentController.shared.openDocument(withContentsOf: first, display: true) { _, _, error in
            if let error { ReaderWindowController.forceNewWindow = false; NSApp.presentError(error); return }
            urls.dropFirst().forEach { WelcomeWindowController.open($0) }
        }
    }

    /// ⌘N: pick a location, create the file, open it straight into edit mode.
    @objc func newMarkdownFile(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = L("Untitled") + ".md"
        panel.canCreateDirectories = true
        if let last = NSDocumentController.shared.recentDocumentURLs.first?.deletingLastPathComponent() {
            panel.directoryURL = last
        }
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            let title = url.deletingPathExtension().lastPathComponent
            do {
                try Data("# \(title)\n\n".utf8).write(to: url, options: .atomic)
            } catch {
                NSApp.presentError(error); return
            }
            ReaderWindowController.openInEditMode.insert(url.standardizedFileURL.path)
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
        if let win = NSApp.keyWindow, win.isVisible { panel.beginSheetModal(for: win, completionHandler: finish) }
        else { finish(panel.runModal()) }
    }

    @objc func setDefaultViewer(_ sender: Any?) {
        guard let appURL = Bundle.main.bundleURL as URL? else { return }
        let types = ["net.daringfireball.markdown"]
        Task { @MainActor in
            var failed: Error?
            for t in types {
                guard let ut = UTType(t) else { continue }
                do { try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: ut) }
                catch { failed = error }
            }
            let alert = NSAlert()
            if let failed {
                alert.messageText = L("Could not set default app")
                alert.informativeText = failed.localizedDescription
            } else {
                alert.messageText = L("MDReader is now the default app for Markdown files.")
            }
            alert.runModal()
        }
    }
}

import UniformTypeIdentifiers

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        let appName = "MDReader"

        // App
        let app = submenu(main, appName)
        app.addItem(withTitle: L("About") + " " + appName,
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: L("Make Default Markdown App"), action: #selector(AppDelegate.setDefaultViewer(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let services = NSMenuItem(title: L("Services"), action: nil, keyEquivalent: "")
        services.submenu = NSMenu()
        NSApp.servicesMenu = services.submenu
        app.addItem(services)
        app.addItem(.separator())
        app.addItem(withTitle: L("Hide") + " " + appName, action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: L("Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: L("Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: L("Quit") + " " + appName, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File
        let file = submenu(main, L("File"))
        file.addItem(withTitle: L("New…"), action: #selector(AppDelegate.newMarkdownFile(_:)), keyEquivalent: "n")
        file.addItem(withTitle: L("Open…"), action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        file.addItem(withTitle: L("Open in New Window…"), action: #selector(AppDelegate.openInNewWindow(_:)), keyEquivalent: "o")
            .keyEquivalentModifierMask = [.command, .option]
        let recent = NSMenuItem(title: L("Open Recent"), action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: L("Open Recent"))
        recentMenu.addItem(withTitle: L("Clear Menu"),
                           action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        recentMenu.perform(NSSelectorFromString("_setMenuName:"), with: "NSRecentDocumentsMenu")
        recent.submenu = recentMenu
        file.addItem(recent)
        file.addItem(.separator())
        file.addItem(withTitle: L("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: L("Save"), action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        file.addItem(withTitle: L("Revert To Saved"), action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("Reload"), action: #selector(ReaderWindowController.reloadDocument(_:)), keyEquivalent: "r")
        file.addItem(.separator())
        file.addItem(withTitle: L("Show in Finder"), action: #selector(ReaderWindowController.revealInFinder(_:)), keyEquivalent: "r")
            .keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: L("Open in External Editor"),
                     action: #selector(ReaderWindowController.openInExternalEditor(_:)), keyEquivalent: "e")
            .keyEquivalentModifierMask = [.command, .option]
        file.addItem(.separator())
        file.addItem(withTitle: L("Export as PDF…"), action: #selector(ReaderWindowController.exportPDF(_:)), keyEquivalent: "e")
            .keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: L("Print…"), action: #selector(ReaderWindowController.printDocument(_:)), keyEquivalent: "p")

        // Edit
        let edit = submenu(main, L("Edit"))
        edit.addItem(withTitle: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: L("Redo"), action: Selector(("redo:")), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Edit"), action: #selector(ReaderWindowController.toggleEditMode(_:)), keyEquivalent: "e")
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Find…"), action: #selector(ReaderWindowController.findInPage(_:)), keyEquivalent: "f")
        edit.addItem(withTitle: L("Find Next"), action: #selector(ReaderWindowController.findNextInPage(_:)), keyEquivalent: "g")
        edit.addItem(withTitle: L("Find Previous"), action: #selector(ReaderWindowController.findPreviousInPage(_:)), keyEquivalent: "g")
            .keyEquivalentModifierMask = [.command, .shift]

        // View
        let view = submenu(main, L("View"))
        view.addItem(withTitle: L("Show Table of Contents"), action: #selector(ReaderWindowController.toggleTOC(_:)), keyEquivalent: "s")
            .keyEquivalentModifierMask = [.command, .control]
        view.addItem(.separator())
        let look = lookMenu()
        for item in look.items { look.removeItem(item); view.addItem(item) }
        view.addItem(.separator())
        view.addItem(withTitle: L("Enter Full Screen"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]

        // Window
        let window = submenu(main, L("Window"))
        window.addItem(withTitle: L("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: L("Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: L("Welcome"), action: #selector(AppDelegate.showWelcome(_:)), keyEquivalent: "1")
            .keyEquivalentModifierMask = [.command, .shift]
        window.addItem(.separator())
        window.addItem(withTitle: L("Bring All to Front"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        return main
    }

    /// Style / appearance / text size — used by the View menu and the toolbar button.
    static func lookMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(header(L("Style")))
        let styles = [L("GitHub"), L("Notion"), L("Academic"), L("Nord")]
        for (i, title) in styles.enumerated() {
            menu.addItem(withTitle: title, action: #selector(ReaderWindowController.setStyle(_:)), keyEquivalent: "").tag = i
        }
        menu.addItem(.separator())
        menu.addItem(header(L("Appearance")))
        for (i, title) in [L("Follow System"), L("Light"), L("Dark")].enumerated() {
            menu.addItem(withTitle: title, action: #selector(ReaderWindowController.setTheme(_:)), keyEquivalent: "").tag = i
        }
        menu.addItem(.separator())
        menu.addItem(header(L("Text Size")))
        menu.addItem(withTitle: L("Zoom In"), action: #selector(ReaderWindowController.zoomInText(_:)), keyEquivalent: "=")
        let alt = menu.addItem(withTitle: L("Zoom In"), action: #selector(ReaderWindowController.zoomInText(_:)), keyEquivalent: "+")
        alt.isHidden = true
        alt.allowsKeyEquivalentWhenHidden = true
        menu.addItem(withTitle: L("Zoom Out"), action: #selector(ReaderWindowController.zoomOutText(_:)), keyEquivalent: "-")
        menu.addItem(withTitle: L("Actual Size"), action: #selector(ReaderWindowController.resetTextZoom(_:)), keyEquivalent: "0")
        return menu
    }

    private static func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func submenu(_ parent: NSMenu, _ title: String) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        parent.addItem(item)
        return menu
    }
}
