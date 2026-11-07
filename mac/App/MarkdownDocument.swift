import Cocoa

/// Markdown document. Edited in-app (autosaved in place, original encoding kept)
/// and reloaded automatically when another app changes the file.
final class MarkdownDocument: NSDocument {

    private(set) var text = ""
    private var encoding: TextDecoding.Encoding = .utf8(bom: false)

    /// Called when the text changed on disk (not for our own edits).
    var onExternalChange: (() -> Void)?

    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        addWindowController(ReaderWindowController())
        WelcomeWindowController.dismiss()
    }

    override func read(from data: Data, ofType typeName: String) throws {
        let result = TextDecoding.detect(data)
        text = result.text
        encoding = result.encoding
    }

    override func data(ofType typeName: String) throws -> Data {
        encoding.encode(text)
    }

    /// Text typed in the editor.
    func applyEdit(_ newText: String) {
        guard newText != text else { return }
        text = newText
        updateChangeCount(.changeDone)
    }

    // MARK: - Live reload

    private var reloadWork: DispatchWorkItem?

    override func presentedItemDidChange() {
        super.presentedItemDidChange()
        scheduleReload()
    }

    override func presentedItemDidMove(to newURL: URL) {
        super.presentedItemDidMove(to: newURL)
        DispatchQueue.main.async { [weak self] in
            self?.windowControllers.forEach { $0.synchronizeWindowTitleWithDocumentName() }
        }
    }

    /// Editors often save in several quick steps; coalesce them.
    private func scheduleReload() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.reloadFromDisk() }
            self.reloadWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
    }

    func reloadFromDisk() {
        // Never clobber unsaved edits made in our own editor.
        guard let url = fileURL, !hasUnautosavedChanges, !isDocumentEdited else { return }
        var coordError: NSError?
        var result: (text: String, encoding: TextDecoding.Encoding)?
        NSFileCoordinator(filePresenter: self).coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            if let data = try? Data(contentsOf: u) { result = TextDecoding.detect(data) }
        }
        guard let result, result.text != text else { return }
        text = result.text
        encoding = result.encoding
        if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            fileModificationDate = date
        }
        onExternalChange?()
    }
}
