import Foundation

/// Decodes text files that may be UTF-8 (with/without BOM), UTF-16, or GB18030,
/// and remembers the encoding so edits are saved back the same way.
enum TextDecoding {

    enum Encoding: Equatable {
        case utf8(bom: Bool)
        case utf16LE, utf16BE
        case gb18030

        static let gbEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

        func encode(_ text: String) -> Data {
            switch self {
            case .utf8(let bom):
                return (bom ? Data([0xEF, 0xBB, 0xBF]) : Data()) + Data(text.utf8)
            case .utf16LE:
                return Data([0xFF, 0xFE]) + (text.data(using: .utf16LittleEndian) ?? Data(text.utf8))
            case .utf16BE:
                return Data([0xFE, 0xFF]) + (text.data(using: .utf16BigEndian) ?? Data(text.utf8))
            case .gb18030:
                // Fall back to UTF-8 if something can't be represented.
                return text.data(using: Self.gbEncoding) ?? Data(text.utf8)
            }
        }
    }

    static func decode(_ data: Data, truncated: Bool = false) -> String {
        detect(data, truncated: truncated).text
    }

    static func detect(_ data: Data, truncated: Bool = false) -> (text: String, encoding: Encoding) {
        if data.isEmpty { return ("", .utf8(bom: false)) }

        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            let body = data.dropFirst(3)
            return (utf8(body, truncated: truncated) ?? String(decoding: body, as: UTF8.self), .utf8(bom: true))
        }
        if data.starts(with: [0xFF, 0xFE]), let s = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            return (s, .utf16LE)
        }
        if data.starts(with: [0xFE, 0xFF]), let s = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            return (s, .utf16BE)
        }
        if let s = utf8(data, truncated: truncated) { return (s, .utf8(bom: false)) }
        if let s = String(data: data, encoding: Encoding.gbEncoding) { return (s, .gb18030) }
        return (String(decoding: data, as: UTF8.self), .utf8(bom: false))
    }

    /// Strict UTF-8 decode. When `truncated`, tolerate a cut multi-byte sequence at the end.
    private static func utf8<D: DataProtocol>(_ bytes: D, truncated: Bool) -> String? {
        let data = Data(bytes)
        if let s = String(data: data, encoding: .utf8) { return s }
        guard truncated else { return nil }
        for cut in 1...3 where data.count > cut {
            if let s = String(data: data.dropLast(cut), encoding: .utf8) { return s }
        }
        return nil
    }
}
