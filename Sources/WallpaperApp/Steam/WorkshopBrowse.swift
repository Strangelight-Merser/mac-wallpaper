import AppKit
import Observation
import SwiftUI
import WELibrary
import WESteam

/// Browsing Wallpaper Engine's Steam Workshop inside the library: query, pages, subscribing.
@MainActor
@Observable
final class WorkshopBrowseModel {
    enum Sort: String, CaseIterable, Identifiable {
        case trend, popular, recent, subscribed
        var id: String { rawValue }
        var query: WorkshopQuery.Sort {
            switch self {
            case .trend: .trend(days: 7)
            case .popular: .popular
            case .recent: .recent
            case .subscribed: .mostSubscribed
            }
        }
    }
    enum Kind: String, CaseIterable, Identifiable {
        case all, scene, video, web
        var id: String { rawValue }
        var tag: String? {
            switch self { case .all: nil; case .scene: "Scene"; case .video: "Video"; case .web: "Web" }
        }
    }
    enum State: Equatable { case idle, loading, failed(String) }

    var sort: Sort = .trend { didSet { reload() } }
    var kind: Kind = .all { didSet { reload() } }
    var search = ""
    var selection: UInt64?
    private(set) var items: [WorkshopItem] = []
    private(set) var total = 0
    private(set) var state: State = .idle
    private(set) var subscribed = Set<UInt64>()
    private var unsubscribed = Set<UInt64>()
    private var cursor: String? = "*"
    private var generation = 0
    let steam: SteamModel
    let library: LibraryModel

    init(steam: SteamModel, library: LibraryModel) { self.steam = steam; self.library = library }

    var selected: WorkshopItem? { items.first { $0.id == selection } }
    /// A first page was requested (so a filter change should reload).
    var loaded: Bool { !items.isEmpty || state != .idle }
    var canLoadMore: Bool { cursor != nil && state == .idle }

    /// Starts over with the current sort, kind, search and maturity setting.
    func reload() {
        generation += 1
        items = []; total = 0; cursor = "*"; state = .idle
        loadMore()
    }

    func loadMore() {
        guard let cursor, state != .loading, steam.account != nil else {
            if steam.account == nil { state = .failed(String(localized: "Log in to Steam to browse the Workshop.")) }
            return
        }
        state = .loading
        let generation = generation
        var required = kind.tag.map { [$0] } ?? []
        var excluded: [String] = []
        if !library.showMature { required.append("Everyone"); excluded = ["Questionable", "Mature"] }
        let text = search.trimmingCharacters(in: .whitespaces)
        let query = WorkshopQuery(sort: text.isEmpty ? sort.query : .textRelevance, searchText: text.isEmpty ? nil : text,
                                  requiredTags: required, excludedTags: excluded, pageSize: 30)
        Task {
            do {
                let page = try await steam.connection.run { client, _ in
                    try await WorkshopBrowser(client: client).query(query, cursor: cursor)
                }
                guard generation == self.generation else { return }
                let known = Set(items.map(\.id))
                items += page.items.filter { $0.result == 1 && !known.contains($0.id) }
                total = page.total
                self.cursor = page.items.isEmpty ? nil : page.nextCursor
                state = .idle
                if subscribed.isEmpty { subscribed = Set(steam.subscriptions.map(\.id)) }
            } catch {
                guard generation == self.generation else { return }
                log("workshop query: \(error)")
                state = .failed(SteamModel.message(error))
            }
        }
    }

    func isInLibrary(_ item: WorkshopItem) -> Bool { library.entries.contains { $0.workshopID == item.id } || steam.queue.contains(item.id) }
    /// Changes made here win over the synced subscription list (which refreshes only on the next sync).
    func isSubscribed(_ item: WorkshopItem) -> Bool {
        subscribed.contains(item.id) || !unsubscribed.contains(item.id) && steam.subscriptions.contains { $0.id == item.id }
    }

    /// Subscribes on Steam (as WE does) and downloads it; the button showed the size.
    func subscribe(_ item: WorkshopItem) {
        Task {
            do {
                try await steam.connection.run { client, _ in try await WorkshopBrowser(client: client).subscribe(item.id) }
                subscribed.insert(item.id); unsubscribed.remove(item.id)
                if !isInLibrary(item) { steam.queue.enqueue([item]) }
            } catch { state = .failed(SteamModel.message(error)) }
        }
    }

    /// Unsubscribes on Steam; the downloaded copy stays in the library until the user removes it.
    func unsubscribe(_ item: WorkshopItem) {
        Task {
            do {
                try await steam.connection.run { client, _ in try await WorkshopBrowser(client: client).unsubscribe(item.id) }
                subscribed.remove(item.id); unsubscribed.insert(item.id)
            } catch { state = .failed(SteamModel.message(error)) }
        }
    }

    func openPage(_ item: WorkshopItem) {
        if let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(item.id)") { NSWorkspace.shared.open(url) }
    }
}

extension WorkshopBrowseModel.Sort {
    var label: Text {
        switch self {
        case .trend: Text("Trending")
        case .popular: Text("Most Popular")
        case .recent: Text("Most Recent")
        case .subscribed: Text("Most Subscribed")
        }
    }
}

extension WorkshopBrowseModel.Kind {
    var label: Text {
        switch self {
        case .all: Text("All Types")
        case .scene: Text("Scene")
        case .video: Text("Video")
        case .web: Text("Web")
        }
    }
}

/// The Workshop grid: small previews only (the user's data is limited), more pages as you scroll.
struct WorkshopBrowseView: View {
    @Bindable var browse: WorkshopBrowseModel
    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker(selection: $browse.sort) {
                    ForEach(WorkshopBrowseModel.Sort.allCases) { $0.label.tag($0) }
                } label: { Text("Sort By") }
                .fixedSize()
                .disabled(!browse.search.trimmingCharacters(in: .whitespaces).isEmpty)
                Picker(selection: $browse.kind) {
                    ForEach(WorkshopBrowseModel.Kind.allCases) { $0.label.tag($0) }
                } label: { Text("Type") }
                .fixedSize()
                Spacer()
                if browse.total > 0 {
                    Text("\(browse.total) wallpapers").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            content
        }
        .task { if browse.items.isEmpty { browse.reload() } }
    }

    @ViewBuilder private var content: some View {
        if browse.items.isEmpty {
            switch browse.state {
            case .failed(let message):
                ContentUnavailableView {
                    Label { Text("Couldn’t Load the Workshop") } icon: { Image(systemName: "exclamationmark.icloud") }
                } description: { Text(message) } actions: {
                    Button { browse.reload() } label: { Text("Try Again") }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loading, .idle:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(browse.items, id: \.id) { item in
                        WorkshopCard(item: item, selected: browse.selection == item.id,
                                     subscribed: browse.isSubscribed(item), inLibrary: browse.isInLibrary(item))
                            .onTapGesture { browse.selection = item.id }
                            .onAppear { if item.id == browse.items.last?.id, browse.canLoadMore { browse.loadMore() } }
                    }
                }
                .padding(16)
                if browse.state == .loading { ProgressView().padding(.bottom, 16) }
                if case .failed(let message) = browse.state {
                    Text(message).font(.callout).foregroundStyle(.secondary).padding(.bottom, 16)
                }
            }
        }
    }
}

private struct WorkshopCard: View {
    let item: WorkshopItem
    let selected: Bool
    let subscribed: Bool
    let inLibrary: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WorkshopImage(url: item.previewURL(width: 400, height: 400), symbol: item.kind?.symbol ?? "photo")
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if inLibrary || subscribed {
                        Image(systemName: inLibrary ? "checkmark.circle.fill" : "bell.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, inLibrary ? Color.green : Color.accentColor)
                            .font(.title3).padding(6)
                            .help(inLibrary ? Text("In your library") : Text("Subscribed"))
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3)
                }
            HStack(spacing: 6) {
                if let kind = item.kind { Image(systemName: kind.symbol).foregroundStyle(.secondary).help(kind.label) }
                Text(item.title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                Text(item.fileSize.formatted(.byteCount(style: .file))).foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.callout)
        }
        .contentShape(Rectangle())
    }
}

/// A 16:9 still preview loaded on demand.
struct WorkshopImage: View {
    let url: URL?
    let symbol: String
    @State private var image: CGImage?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: symbol).font(.largeTitle).foregroundStyle(.tertiary)
                }
            }
            .clipped()
            .task(id: url) {
                image = nil
                if let url { image = await WorkshopPreviews.shared.image(url) }
            }
    }
}

/// Workshop previews as still images, for as little data as possible (the user's data is limited): JPEG and PNG
/// previews come as small renditions (`WorkshopItem.previewURL(width:height:)`); animated GIFs, which Steam never
/// resizes and often weigh a megabyte, are read in ranges only until their first frame is complete.
actor WorkshopPreviews {
    static let shared = WorkshopPreviews()
    private let cache = NSCache<NSURL, CGImage>()
    private var loading: [URL: Task<CGImage?, Never>] = [:]
    private static let step = 64 * 1024, limit = 512 * 1024

    init() { cache.countLimit = 400 }

    func image(_ url: URL) async -> CGImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        if let task = loading[url] { return await task.value }
        let task = Task { await Self.load(url) }
        loading[url] = task
        let image = await task.value
        loading[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }

    private static func load(_ url: URL) async -> CGImage? {
        var data = Data()
        while true {
            var request = URLRequest(url: url)
            request.setValue("bytes=\(data.count)-\(data.count + step - 1)", forHTTPHeaderField: "Range")
            guard let (chunk, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse else { return nil }
            let complete: Bool
            switch http.statusCode {
            case 206:
                data += chunk
                // Content-Range: bytes <first>-<last>/<total>
                let total = http.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap { Int($0) }
                complete = total.map { data.count >= $0 } ?? (chunk.count < step)
            case 200: data = chunk; complete = true  // the server sent the whole file
            case 416: complete = true                // the previous range ended exactly at the end
            default: return nil
            }
            if complete || data.count >= limit {
                return CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            }
            // A GIF cut after a frame plus a trailer byte is a complete GIF. Some start on a blank frame (a fade
            // in): then the latest frame in the bytes at hand, or in the next range.
            let ends = gifFrameEnds(data)
            if let end = ends.last {
                let image = CGImageSourceCreateWithData((data.prefix(end) + [0x3B]) as CFData, nil)
                    .flatMap { CGImageSourceCreateImageAtIndex($0, ends.count - 1, nil) }
                if let image, !isBlank(image) || data.count + step > limit { return image }
            }
            if Task.isCancelled { return nil }
        }
    }

    /// Where each complete image's data ends in a (partial) GIF; empty if it isn't a GIF or no frame is
    /// complete yet (GIF89a: header, logical screen descriptor, color table, then extension and image blocks).
    static func gifFrameEnds(_ data: Data) -> [Int] {
        let b = [UInt8](data)
        guard b.count >= 13, b.starts(with: Array("GIF8".utf8)) else { return [] }
        var pos = 13 + (b[10] & 0x80 != 0 ? 3 << ((Int(b[10]) & 7) + 1) : 0)
        var ends: [Int] = []
        func skipSubBlocks() -> Bool {
            while pos < b.count {
                let size = Int(b[pos]); pos += 1
                if size == 0 { return true }
                pos += size
            }
            return false
        }
        while pos < b.count {
            switch b[pos] {
            case 0x21:  // extension: label, then sub-blocks
                pos += 2
                guard skipSubBlocks() else { return ends }
            case 0x2C:  // image descriptor (10 bytes), local color table, LZW code size, data sub-blocks
                guard pos + 10 <= b.count else { return ends }
                let flags = Int(b[pos + 9])
                pos += 10 + (flags & 0x80 != 0 ? 3 << ((flags & 7) + 1) : 0) + 1
                guard skipSubBlocks() else { return ends }
                ends.append(pos)
            default:
                return ends
            }
        }
        return ends
    }

    /// Nearly one flat color (judged from an 8×8 thumbnail).
    static func isBlank(_ image: CGImage) -> Bool {
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        guard let context = CGContext(data: &pixels, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        let luma = stride(from: 0, to: pixels.count, by: 4).map { Int(pixels[$0]) * 3 + Int(pixels[$0 + 1]) * 6 + Int(pixels[$0 + 2]) }
        return (luma.max() ?? 0) - (luma.min() ?? 0) < 60
    }
}

/// Details of the selected Workshop item, with subscribing.
struct WorkshopInspector: View {
    let browse: WorkshopBrowseModel

    var body: some View {
        if let item = browse.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    WorkshopImage(url: item.previewURL(width: 640, height: 640), symbol: item.kind?.symbol ?? "photo")
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                        HStack(spacing: 6) {
                            if let kind = item.kind { Label { Text(kind.label) } icon: { Image(systemName: kind.symbol) } }
                            if let rating = item.rating { Text(verbatim: "·"); Text(rating.label) }
                        }
                        .font(.callout).foregroundStyle(.secondary)
                    }
                    actions(item)
                    if item.kind == .video || item.kind == .web {
                        Label { Text("Videos and web pages work on Mac.") } icon: {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                        .font(.callout)
                    } else if item.kind == .preset {
                        Label {
                            Text("Presets aren’t supported yet. A preset changes the settings of another wallpaper, which it needs too.")
                        } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow) }
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    } else if item.kind == .scene {
                        Text("Whether a scene works fully on this Mac is checked after it downloads.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let text = item.shortDescription, !text.isEmpty {
                        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    let tags = item.tags.filter { !["Scene", "Video", "Web", "Preset", "Everyone", "Questionable", "Mature"].contains($0) }
                    if !tags.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Tags").font(.headline)
                            TagList(tags: tags)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Details").font(.headline)
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                            GridRow { Text("Size").foregroundStyle(.secondary); Text(item.fileSize.formatted(.byteCount(style: .file))) }
                            GridRow { Text("Updated").foregroundStyle(.secondary); Text(item.timeUpdated.formatted(date: .abbreviated, time: .omitted)) }
                            if let n = item.subscriptions {
                                GridRow { Text("Subscribers").foregroundStyle(.secondary); Text(n.formatted()) }
                            }
                            GridRow { Text("Workshop ID").foregroundStyle(.secondary); Text(verbatim: String(item.id)).textSelection(.enabled) }
                        }
                        .font(.callout)
                    }
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView {
                Label { Text("No Selection") } icon: { Image(systemName: "cursorarrow.click") }
            } description: { Text("Select a wallpaper to see its details.") }
        }
    }

    @ViewBuilder private func actions(_ item: WorkshopItem) -> some View {
        HStack {
            if browse.isInLibrary(item) {
                Button {} label: { Text("In Your Library").frame(maxWidth: .infinity) }
                    .controlSize(.large).disabled(true)
            } else {
                Button { browse.subscribe(item) } label: {
                    Text("Subscribe and Download (\(item.fileSize.formatted(.byteCount(style: .file))))").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(item.kind == .application || item.kind == .preset)
            }
            Menu {
                if browse.isSubscribed(item) {
                    Button { browse.unsubscribe(item) } label: { Text("Unsubscribe") }
                }
                Button { browse.openPage(item) } label: { Text("Open Workshop Page") }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().controlSize(.large)
        }
    }
}
