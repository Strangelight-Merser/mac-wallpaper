import Foundation
import WEFormat

/// A directory to search for wallpaper projects.
public struct LibraryRoot: Codable, Sendable, Hashable {
    /// `bundled`: wallpapers that come with the app (its Resources/Wallpapers).
    public enum Kind: String, Codable, Sendable { case steamWorkshop, downloads, userFolder, bundled }
    public var url: URL
    public var kind: Kind

    public init(url: URL, kind: Kind) { self.url = url; self.kind = kind }
}

/// Conventional Steam and application download locations.
public enum LibraryRoots {
    public static var downloads: LibraryRoot {
        LibraryRoot(url: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacWallpaper/Workshop"), kind: .downloads)
    }

    /// Existing workshop folders from Steam's default library and libraryfolders.vdf.
    public static func steamWorkshopRoots() -> [LibraryRoot] {
        steamWorkshopRoots(steam: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam"))
    }

    static func steamWorkshopRoots(steam: URL) -> [LibraryRoot] {
        var libraries = [steam]
        if let text = try? String(contentsOf: steam.appendingPathComponent("steamapps/libraryfolders.vdf"), encoding: .utf8),
           let value = try? VDF.parse(text) {
            for pair in value["libraryfolders"]?.pairs ?? [] where Int(pair.key) != nil {
                if let path = pair.value["path"]?.string ?? pair.value.string {
                    libraries.append(URL(fileURLWithPath: path))
                }
            }
        }
        var seen = Set<String>()
        return libraries.compactMap {
            let url = $0.appendingPathComponent("steamapps/workshop/content/431960").standardizedFileURL
            guard seen.insert(url.path).inserted, isDirectory(url) else { return nil }
            return LibraryRoot(url: url, kind: .steamWorkshop)
        }
    }

    /// Scans the root and its children; user folders are searched through depth three.
    public static func discover(_ roots: [LibraryRoot]) -> [(folder: URL, root: LibraryRoot.Kind)] {
        var result: [(URL, LibraryRoot.Kind)] = []
        var seen = Set<String>()
        func visit(_ folder: URL, kind: LibraryRoot.Kind, depth: Int) {
            guard !folder.lastPathComponent.hasPrefix("."), !folder.lastPathComponent.hasSuffix(".partial"),
                  isDirectory(folder), !isSymlink(folder) else { return }
            let path = folder.standardizedFileURL
            if isRegularFile(path.appendingPathComponent("project.json")), seen.insert(path.path).inserted {
                result.append((path, kind))
            }
            guard depth > 0 else { return }
            let children = (try? FileManager.default.contentsOfDirectory(at: path,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: .skipsHiddenFiles)) ?? []
            for child in children.sorted(by: { $0.path < $1.path }) { visit(child, kind: kind, depth: depth - 1) }
        }
        for root in roots { visit(root.url, kind: root.kind, depth: root.kind == .userFolder ? 3 : 1) }
        return result
    }
}

func isDirectory(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
func isSymlink(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true }
func isRegularFile(_ url: URL) -> Bool {
    !isSymlink(url) && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
}
