import Foundation

/// A wallpaper property's label as the panel shows it: plain text, plus a link if the author wrapped it in one.
struct PropertyLabel: Equatable {
    var text: String
    var link: URL?
}

enum PropertyText {
    /// Labels are either WE localization keys (`ui_browse_properties_scheme_color`) or the author's text,
    /// which may contain simple HTML (`<a href='…'>…</a>`, `<br>`, entities).
    static func label(_ raw: String) -> PropertyLabel {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ui_"), !trimmed.contains(" ") { return PropertyLabel(text: weKey(trimmed)) }
        var link: URL?
        if let m = trimmed.range(of: #"<a\s+href\s*=\s*['"]([^'"]*)['"]"#, options: [.regularExpression, .caseInsensitive]) {
            let tag = String(trimmed[m])
            if let q = tag.firstIndex(where: { $0 == "'" || $0 == "\"" }) {
                let url = tag[tag.index(after: q)...].dropLast()
                link = URL(string: String(url).trimmingCharacters(in: .whitespaces)).flatMap { $0.scheme == "https" || $0.scheme == "http" ? $0 : nil }
            }
        }
        var text = trimmed.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, char) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        text = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return PropertyLabel(text: text, link: link)
    }

    /// WE's own keys seen in the user's wallpapers, localized; others are spelled out from the key.
    static func weKey(_ key: String) -> String {
        switch key {
        case "ui_browse_properties_scheme_color": return String(localized: "Scheme color")
        case "ui_browse_properties_accent_color": return String(localized: "Accent color")
        case "ui_browse_properties_background_color": return String(localized: "Background color")
        case "ui_editor_properties_brightness": return String(localized: "Brightness")
        case "ui_editor_properties_speed": return String(localized: "Speed")
        case "ui_editor_properties_length": return String(localized: "Length")
        case "ui_editor_properties_mode": return String(localized: "Mode")
        case "ui_browse_properties_count": return String(localized: "Count")
        case "ui_browse_properties_style": return String(localized: "Style")
        case "ui_browse_properties_glow": return String(localized: "Glow")
        case "ui_browse_properties_clouds": return String(localized: "Clouds")
        case "ui_browse_properties_large": return String(localized: "Large")
        case "ui_browse_properties_small": return String(localized: "Small")
        default:
            var name = key
            for prefix in ["ui_browse_properties_", "ui_editor_properties_", "ui_"] where name.hasPrefix(prefix) {
                name = String(name.dropFirst(prefix.count)); break
            }
            let words = name.split(separator: "_").map(String.init)
            guard let first = words.first else { return key }
            return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
        }
    }
}
