import AppKit
import QuickLookThumbnailing

/// Finder / Quick Look thumbnail: renders the first page of the Markdown file.
final class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let text: String
        do {
            // Only the beginning of the file matters for a thumbnail.
            let handle = try FileHandle(forReadingFrom: request.fileURL)
            defer { try? handle.close() }
            let limit = 48 * 1024
            let data = try handle.read(upToCount: limit) ?? Data()
            text = TextDecoding.decode(data, truncated: data.count >= limit)
        } catch {
            handler(nil, error)
            return
        }

        let size = MarkdownThumbnail.pageSize(fitting: request.maximumSize)
        let reply = QLThumbnailReply(contextSize: size, currentContextDrawing: { () -> Bool in
            MarkdownThumbnail.drawPage(markdown: text, size: size)
            return true
        })
        reply.extensionBadge = "MD"
        handler(reply, nil)
    }
}
