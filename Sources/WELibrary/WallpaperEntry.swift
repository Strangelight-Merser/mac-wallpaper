import Foundation
import CryptoKit
import WEFormat

/// The project entry point's renderer family.
public enum WallpaperType: String, Codable, Sendable, CaseIterable {
    case scene, video, web, application, unknown
}

/// Wallpaper Engine's content ratings.
public enum ContentRating: String, Codable, Sendable {
    case everyone = "Everyone", questionable = "Questionable", mature = "Mature"
}

/// Library metadata, including malformed fields and the last compatibility result.
public struct WallpaperEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var folder: URL
    public var root: LibraryRoot.Kind
    public var title: String
    public var type: WallpaperType
    public var file: String
    public var preview: URL?
    public var tags: [String]
    public var contentRating: ContentRating
    public var workshopID: UInt64?
    public var hasUserProperties: Bool
    public var audioResponsive: Bool
    public var sizeOnDisk: Int64
    public var modified: Date
    public var compatibility: Compatibility?
    public var problems: [String]
    public var duplicateOf: String?

    /// Reads lenient project JSON; invalid fields are reported without losing the folder.
    public init(folder: URL, root: LibraryRoot.Kind) {
        self.folder = folder.standardizedFileURL
        self.root = root
        let locator = AssetLocator(project: folder, assets: nil)
        var issues: [String] = []
        let project: [String: Any]
        do { project = try locator.json("project.json") }
        catch { project = [:]; issues.append("project.json: \(error)") }
        func text(_ key: String, required: Bool = false) -> String? {
            guard let value = project[key] else {
                if required { issues.append("missing \(key)") }
                return nil
            }
            guard let string = value as? String, !string.isEmpty else { issues.append("invalid \(key)"); return nil }
            return string
        }
        title = text("title", required: true) ?? folder.lastPathComponent
        file = text("file", required: true) ?? ""
        let rawType = text("type")?.lowercased()
        type = rawType.flatMap(WallpaperType.init(rawValue:)) ?? (rawType == nil ? Self.inferredType(file) : .unknown)
        if type == .unknown { issues.append("missing or unknown type") }
        if let raw = project["workshopid"] {
            let string = (raw as? String) ?? (raw as? NSNumber).map { $0.stringValue }
            workshopID = string.flatMap(UInt64.init)
            if workshopID == nil || workshopID == 0 { workshopID = nil; issues.append("invalid workshopid") }
        }
        id = workshopID.map { "ws:\($0)" } ?? "dir:\(pathHash(self.folder.path))"
        tags = []
        if let raw = project["tags"] {
            if let array = raw as? [Any] {
                tags = array.compactMap { $0 as? String }
                if tags.count != array.count { issues.append("invalid tags") }
            } else { issues.append("invalid tags") }
        }
        contentRating = .everyone
        if let raw = text("contentrating") {
            if let rating = [ContentRating.everyone, .questionable, .mature].first(where: { $0.rawValue.lowercased() == raw.lowercased() }) {
                contentRating = rating
            } else { issues.append("invalid contentrating") }
        }
        if let path = text("preview") {
            if locator.exists(path) { preview = locator.url(path) }
            if preview == nil { issues.append("preview not found: \(path)") }
        }
        let general = project["general"] as? [String: Any] ?? [:]
        if project["general"] != nil, project["general"] as? [String: Any] == nil { issues.append("invalid general") }
        let properties = general["properties"] as? [String: Any] ?? [:]
        if general["properties"] != nil, general["properties"] as? [String: Any] == nil { issues.append("invalid general.properties") }
        hasUserProperties = properties.keys.contains { $0 != "schemecolor" }
        audioResponsive = general["supportsaudioprocessing"] as? Bool ?? false
        if general["supportsaudioprocessing"] != nil, general["supportsaudioprocessing"] as? Bool == nil {
            issues.append("invalid general.supportsaudioprocessing")
        }
        sizeOnDisk = 0
        if let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) {
            for case let url as URL in files {
                if isSymlink(url) { files.skipDescendants(); continue }
                if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true {
                    sizeOnDisk += Int64(values.fileSize ?? 0)
                }
            }
        }
        modified = folderStamps(folder: self.folder, file: file).compactMap(\.modified).max() ?? .distantPast
        problems = issues
    }
}

func pathHash(_ path: String) -> String {
    SHA256.hash(data: Data(path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
}

struct FileStamp: Codable, Equatable {
    let path: String
    let size: Int64?
    let modified: Date?

    init(_ url: URL) {
        path = url.standardizedFileURL.path
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        size = (attributes?[.size] as? NSNumber)?.int64Value
        modified = attributes?[.modificationDate] as? Date
    }
}

func folderStamps(folder: URL, file: String) -> [FileStamp] {
    ["project.json", file, "scene.pkg"].filter { !$0.isEmpty }.map { FileStamp(folder.appendingPathComponent($0)) }
}

extension WallpaperEntry {
    /// Older and official projects (e.g. "Sheep", a Unity .exe) omit "type"; infer it from the main file.
    static func inferredType(_ file: String) -> WallpaperType {
        switch (file as NSString).pathExtension.lowercased() {
        case "json": return .scene
        case "exe": return .application
        case "html", "htm": return .web
        case "mp4", "m4v", "mov", "webm", "avi", "mkv", "wmv": return .video
        default: return .unknown
        }
    }
}
