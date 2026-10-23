import AppKit
import Observation
import WELibrary
import WERender

/// What the sidebar selects: a type filter or one source of wallpapers.
enum LibrarySection: Hashable {
    case all
    case type(WallpaperType)
    case steamWorkshop
    case downloads
    case folder(URL)
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case title, recent, size
    var id: String { rawValue }
}

/// State behind the library window: the index, filters, selection and the apply action.
@MainActor
@Observable
final class LibraryModel {
    private(set) var entries: [WallpaperEntry] = []
    private(set) var isRefreshing = false
    private(set) var isCheckingDeep = false
    var section: LibrarySection = .all
    var search = ""
    var sort: LibrarySort = .recent
    /// Default view: only wallpapers that run on this Mac (supported or partly supported).
    var onlyRunnable = true
    var showMature = false
    var selection: WallpaperEntry.ID?
    var inspectorShown = true
    /// The wallpaper currently on the desktop (folder path), for the "current" mark.
    var currentPath: String?

    private(set) var folders: [URL]
    private let library = WallpaperLibrary()
    private let defaults = UserDefaults.standard
    /// Set by the app delegate: shows a wallpaper on the desktop.
    var apply: (WallpaperEntry) -> Void = { _ in }
    /// Set by the app delegate: the current wallpaper's display mode changed.
    var contentModeChanged: (ContentMode) -> Void = { _ in }
    /// Display mode per wallpaper folder (only non-default choices are stored).
    private(set) var contentModes: [String: String] = UserDefaults.standard.dictionary(forKey: "contentModes") as? [String: String] ?? [:]

    init() {
        folders = (UserDefaults.standard.stringArray(forKey: "libraryFolders") ?? []).map { URL(fileURLWithPath: $0) }
        currentPath = UserDefaults.standard.string(forKey: "wallpaper")
    }

    var assets: URL? { defaults.string(forKey: "assets").map { URL(fileURLWithPath: $0) } }

    var roots: [LibraryRoot] {
        LibraryRoots.steamWorkshopRoots() + [LibraryRoots.downloads]
            + folders.map { LibraryRoot(url: $0, kind: .userFolder) }
    }

    var selected: WallpaperEntry? { entries.first { $0.id == selection } }

    /// Entries for the current section, search, filters and sort order.
    var visible: [WallpaperEntry] {
        filtered(section, query: search, onlyRunnable: onlyRunnable, showMature: showMature).sorted { a, b in
            switch sort {
            case .title: return a.title.localizedStandardCompare(b.title) == .orderedAscending
            case .recent: return a.modified > b.modified
            case .size: return a.sizeOnDisk > b.sizeOnDisk
            }
        }
    }

    /// In the current section but hidden by the filters or the search (hint under the grid).
    var hiddenCount: Int {
        filtered(section, query: "", onlyRunnable: false, showMature: true).count - visible.count
    }

    /// Sidebar badge: what the section would show with the current filters (search ignored).
    func count(_ section: LibrarySection) -> Int {
        filtered(section, query: "", onlyRunnable: onlyRunnable, showMature: showMature).count
    }

    private func filtered(_ section: LibrarySection, query: String, onlyRunnable: Bool, showMature: Bool) -> [WallpaperEntry] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.filter { e in
            switch section {
            case .all: break
            case .type(let t): guard e.type == t else { return false }
            case .steamWorkshop: guard e.root == .steamWorkshop else { return false }
            case .downloads: guard e.root == .downloads else { return false }
            case .folder(let url): guard e.folder.path.hasPrefix(url.path + "/") else { return false }
            }
            if !showMature && e.contentRating != .everyone { return false }
            if onlyRunnable, e.compatibility?.status == .unsupported { return false }
            if !query.isEmpty {
                let haystack = ([e.title] + e.tags).joined(separator: " ").lowercased()
                guard haystack.contains(query) || e.workshopID.map(String.init) == query else { return false }
            }
            return true
        }
    }

    // MARK: - refresh

    /// Fast static scan first so the window fills quickly, then the rendering check in the background.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let roots = self.roots, assets = self.assets
        _ = await library.refresh(roots: roots, assets: assets, deep: false)
        entries = await library.entries()
        isRefreshing = false
        isCheckingDeep = true
        _ = await library.refresh(roots: roots, assets: assets, deep: true)
        entries = await library.entries()
        isCheckingDeep = false
    }

    // MARK: - folders

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose folders that contain Wallpaper Engine wallpapers")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !folders.contains(url) { folders.append(url) }
        saveFolders()
        Task { await refresh() }
    }

    func removeFolder(_ url: URL) {
        folders.removeAll { $0 == url }
        if section == .folder(url) { section = .all }
        saveFolders()
        Task { await refresh() }
    }

    private func saveFolders() { defaults.set(folders.map(\.path), forKey: "libraryFolders") }

    func chooseAssets() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = String(localized: "Choose Wallpaper Engine's “assets” folder")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        defaults.set(url.path, forKey: "assets")
        Task { await refresh() }
    }

    // MARK: - actions

    func setAsWallpaper(_ entry: WallpaperEntry) {
        currentPath = entry.folder.path
        apply(entry)
    }

    func revealInFinder(_ entry: WallpaperEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.folder])
    }

    func openWorkshopPage(_ entry: WallpaperEntry) {
        guard let id = entry.workshopID,
              let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)") else { return }
        NSWorkspace.shared.open(url)
    }

    func contentMode(for entry: WallpaperEntry) -> ContentMode {
        contentModes[entry.folder.standardizedFileURL.path].flatMap(ContentMode.init(rawValue:)) ?? .fill
    }

    func setContentMode(_ mode: ContentMode, for entry: WallpaperEntry) {
        contentModes[entry.folder.standardizedFileURL.path] = mode == .fill ? nil : mode.rawValue
        defaults.set(contentModes, forKey: "contentModes")
        if isCurrent(entry) { contentModeChanged(mode) }
    }

    /// The stored display mode of a wallpaper folder, for the app at load time.
    static func storedContentMode(path: String) -> ContentMode {
        let modes = UserDefaults.standard.dictionary(forKey: "contentModes") as? [String: String] ?? [:]
        return modes[URL(fileURLWithPath: path).standardizedFileURL.path].flatMap(ContentMode.init(rawValue:)) ?? .fill
    }

    func isCurrent(_ entry: WallpaperEntry) -> Bool {
        currentPath.map { URL(fileURLWithPath: $0).standardizedFileURL == entry.folder.standardizedFileURL } ?? false
    }
}
