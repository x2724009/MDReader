import Cocoa

/// User preferences shared by all windows.
enum Settings {
    enum Theme: String, CaseIterable { case auto, light, dark }
    enum Style: String, CaseIterable { case github, notion, academic, nord }

    static let didChange = Notification.Name("MDReaderSettingsDidChange")
    private static let d = UserDefaults.standard

    static var theme: Theme {
        get { Theme(rawValue: d.string(forKey: "theme") ?? "") ?? .auto }
        set { d.set(newValue.rawValue, forKey: "theme"); post() }
    }

    static var style: Style {
        get { Style(rawValue: d.string(forKey: "style") ?? "") ?? .github }
        set { d.set(newValue.rawValue, forKey: "style"); post() }
    }

    static var zoom: Double {
        get { let z = d.double(forKey: "zoom"); return z == 0 ? 1 : z }
        set { d.set(min(max(newValue, 0.6), 2.4), forKey: "zoom"); post() }
    }

    static var showTOC: Bool {
        get { d.object(forKey: "showTOC") as? Bool ?? true }
        set { d.set(newValue, forKey: "showTOC"); post() }
    }

    /// Open documents as tabs of one window (true) or each in its own window.
    static var openInTabs: Bool {
        get { d.object(forKey: "openInTabs") as? Bool ?? true }
        set { d.set(newValue, forKey: "openInTabs"); post() }
    }

    /// "outline" or "files". Remembered silently (no broadcast).
    static var sidebarTab: String {
        get { d.string(forKey: "sidebarTab") ?? "outline" }
        set { d.set(newValue, forKey: "sidebarTab") }
    }

    /// Last page background reported by the renderer, so new windows open in the right colour.
    static var lastBackground: NSColor {
        get { NSColor(hex: d.string(forKey: "lastBG") ?? "") ?? .textBackgroundColor }
        set { d.set(newValue.hexString, forKey: "lastBG") }
    }

    static var appearance: NSAppearance? {
        switch theme {
        case .auto: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    static var javaScriptValue: [String: Any] {
        let lang = Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh" : "en"
        return ["style": style.rawValue, "theme": theme.rawValue, "zoom": zoom, "toc": showTOC, "lang": lang, "sidebarTab": sidebarTab]
    }

    private static func post() { NotificationCenter.default.post(name: didChange, object: nil) }
}

extension NSColor {
    /// Accepts "#rgb", "#rrggbb" or "rgb(r, g, b)".
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("rgb") {
            let nums = s.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
                .compactMap(Double.init)
            guard nums.count >= 3 else { return nil }
            self.init(srgbRed: nums[0] / 255, green: nums[1] / 255, blue: nums[2] / 255, alpha: 1)
            return
        }
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#ffffff" }
        return String(format: "#%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255),
                      Int(c.blueComponent * 255))
    }
}
