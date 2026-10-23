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
    private var cursor: String? = "*"
    private var generation = 0
    let steam: SteamModel
    let library: LibraryModel

    init(steam: SteamModel, library: LibraryModel) { self.steam = steam; self.library = library }

    var selected: WorkshopItem? { items.first { $0.id == selection } }
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
                state = .failed(SteamModel.message(error))
            }
        }
    }

    func isInLibrary(_ item: WorkshopItem) -> Bool { library.entries.contains { $0.workshopID == item.id } || steam.queue.contains(item.id) }
    func isSubscribed(_ item: WorkshopItem) -> Bool { subscribed.contains(item.id) || steam.subscriptions.contains { $0.id == item.id } }

    /// Subscribes on Steam (as WE does) and downloads it; the button showed the size.
    func subscribe(_ item: WorkshopItem) {
        Task {
            do {
                try await steam.connection.run { client, _ in try await WorkshopBrowser(client: client).subscribe(item.id) }
                subscribed.insert(item.id)
                if !isInLibrary(item) { steam.queue.enqueue([item]) }
            } catch { state = .failed(SteamModel.message(error)) }
        }
    }

    /// Unsubscribes on Steam; the downloaded copy stays in the library until the user removes it.
    func unsubscribe(_ item: WorkshopItem) {
        Task {
            do {
                try await steam.connection.run { client, _ in try await WorkshopBrowser(client: client).unsubscribe(item.id) }
                subscribed.remove(item.id)
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
                TextField(text: $browse.search) { Text("Search the Workshop") }
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onSubmit { browse.reload() }
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
            WorkshopImage(url: item.previewURL(width: 384, height: 216), symbol: item.kind?.symbol ?? "photo")
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

/// A 16:9 preview loaded on demand.
struct WorkshopImage: View {
    let url: URL?
    let symbol: String

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: symbol).font(.largeTitle).foregroundStyle(.tertiary)
                    }
                }
            }
            .clipped()
    }
}

/// Details of the selected Workshop item, with subscribing.
struct WorkshopInspector: View {
    let browse: WorkshopBrowseModel

    var body: some View {
        if let item = browse.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    WorkshopImage(url: item.previewURL(width: 640, height: 360), symbol: item.kind?.symbol ?? "photo")
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
                    } else if item.kind == .scene {
                        Text("Whether a scene works fully on this Mac is checked after it downloads.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let text = item.shortDescription, !text.isEmpty {
                        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    let tags = item.tags.filter { !["Scene", "Video", "Web", "Everyone", "Questionable", "Mature"].contains($0) }
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
                .disabled(item.kind == .application)
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
