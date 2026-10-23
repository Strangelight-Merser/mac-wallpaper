import SwiftUI
import WELibrary
import WESteam

/// "Bring your Wallpaper Engine subscriptions over": a pre-selected list with sizes, downloaded in the background.
struct ImportSheet: View {
    @Bindable var steam: SteamModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your Steam Subscriptions").font(.title2.weight(.semibold))
                Text("Wallpapers you subscribed to in Wallpaper Engine. Choose which to download to this Mac; they download in the background and appear in the library as each one finishes.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch steam.subscriptionsState {
            case .idle, .loading:
                HStack { Spacer(); ProgressView { Text("Reading your subscriptions…") }; Spacer() }
                    .frame(height: 320)
            case .failed(let message):
                VStack(spacing: 12) {
                    Text(message).foregroundStyle(.secondary)
                    if steam.account == nil {
                        Button { steam.importSheetShown = false; steam.showLogin() } label: { Text("Log In to Steam…") }
                    } else {
                        Button { Task { await steam.loadSubscriptions() } } label: { Text("Try Again") }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 320)
            case .loaded:
                if steam.subscriptions.isEmpty {
                    Text("You haven’t subscribed to any Wallpaper Engine wallpapers on Steam yet.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    summary
                    quickChoices
                    list
                }
            }

            HStack {
                Text("Cover images aren’t loaded here, to save data.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(role: .cancel) { steam.importSheetShown = false } label: { Text("Not Now") }
                    .keyboardShortcut(.cancelAction)
                Button { steam.downloadChosen() } label: {
                    Text("Download \(steam.chosen.count) (\(steam.chosenBytes.formatted(.byteCount(style: .file))))")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(steam.chosen.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 640)
    }

    private var summary: some View {
        let items = steam.subscriptions
        let total = items.reduce(0) { $0 + $1.fileSize }
        let kinds: [WorkshopItem.Kind] = [.scene, .video, .web]
        let counts = kinds.compactMap { kind -> (label: String, count: Int)? in
            let count = items.filter { $0.kind == kind }.count
            return count > 0 ? (kind.label, count) : nil
        }
        return HStack(spacing: 6) {
            Text("\(items.count) wallpapers, \(total.formatted(.byteCount(style: .file)))").font(.headline)
            ForEach(counts, id: \.label) { entry in
                Text(verbatim: "·").foregroundStyle(.secondary)
                Text(verbatim: "\(entry.label) \(entry.count)").foregroundStyle(.secondary)
            }
        }
    }

    private var quickChoices: some View {
        HStack(spacing: 10) {
            Text("Select:").foregroundStyle(.secondary)
            Button { steam.chosen = Set(steam.subscriptions.filter { steam.isDefaultChoice($0) }.map(\.id)) } label: { Text("All New") }
            Button {
                steam.chosen = Set(steam.subscriptions.filter { steam.isDefaultChoice($0) && ($0.kind == .video || $0.kind == .web) }.map(\.id))
            } label: { Text("Videos and Web Pages") }
                .help(Text("These always play on Mac; scenes may miss some parts."))
            Button {
                steam.chosen = Set(steam.subscriptions.filter { steam.isDefaultChoice($0) && $0.fileSize < 100_000_000 }.map(\.id))
            } label: { Text("Under 100 MB") }
            Button { steam.chosen = [] } label: { Text("None") }
        }
        .buttonStyle(.link)
        .font(.callout)
    }

    private var list: some View {
        List(steam.subscriptions, id: \.id) { item in
            let present = steam.isInLibrary(item)
            HStack(spacing: 10) {
                Toggle(isOn: Binding(
                    get: { steam.chosen.contains(item.id) },
                    set: { on in if on { steam.chosen.insert(item.id) } else { steam.chosen.remove(item.id) } }
                )) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(present)
                Image(systemName: item.kind?.wallpaperType.symbol ?? "questionmark.square")
                    .foregroundStyle(.secondary).frame(width: 18)
                    .help(item.kind?.label ?? "")
                Text(item.title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                if present {
                    Text("In Library").font(.caption).foregroundStyle(.secondary)
                } else if let rating = item.rating, rating != .everyone {
                    Text(rating.wallpaperRating.label).font(.caption).foregroundStyle(.orange)
                }
                Text(item.fileSize.formatted(.byteCount(style: .file)))
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .trailing)
            }
            .opacity(present ? 0.55 : 1)
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
        .frame(height: 320)
    }
}

extension WorkshopItem.Kind {
    var wallpaperType: WallpaperType {
        switch self {
        case .scene: .scene
        case .video: .video
        case .web: .web
        case .application: .application
        case .preset: .scene
        }
    }
    var label: String { self == .preset ? String(localized: "Preset") : wallpaperType.label }
    var symbol: String { wallpaperType.symbol }
}

extension WorkshopItem.Rating {
    var label: String { wallpaperRating.label }
    var wallpaperRating: ContentRating {
        switch self {
        case .everyone: .everyone
        case .questionable: .questionable
        case .mature: .mature
        }
    }
}

/// Toolbar popover listing the download queue.
struct DownloadsPopover: View {
    let queue: DownloadQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                if queue.downloads.contains(where: { !$0.isActive }) {
                    Button { queue.clearFinished() } label: { Text("Clear Finished") }.buttonStyle(.link)
                }
            }
            if queue.downloads.isEmpty {
                Text("Nothing is downloading.").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(queue.downloads) { download in
                        DownloadRow(download: download, cancel: { queue.cancel(download.id) }, retry: { queue.retry(download.id) })
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .padding(14)
        .frame(width: 340)
    }
}

private struct DownloadRow: View {
    let download: DownloadQueue.Download
    let cancel: () -> Void
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(download.item.title).lineLimit(1).truncationMode(.tail)
                Spacer()
                if download.isActive {
                    Button(action: cancel) { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help(Text("Cancel"))
                }
            }
            switch download.state {
            case .queued:
                Text("Waiting").font(.caption).foregroundStyle(.secondary)
            case .preparing:
                ProgressView().progressViewStyle(.linear)
            case .downloading(let done, let total):
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text("\(done.formatted(.byteCount(style: .file))) of \(total.formatted(.byteCount(style: .file)))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            case .finished:
                Label {
                    download.kind == .new ? Text("Added to the library") : Text("Updated")
                } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    .font(.caption)
            case .held(let reason):
                Label { Text(reason.explanation) } icon: { Image(systemName: "pause.circle.fill").foregroundStyle(.orange) }
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let message):
                HStack {
                    Label { Text(message) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    Spacer()
                    Button(action: retry) { Text("Retry") }.buttonStyle(.link)
                }
                .font(.caption)
            case .cancelled:
                HStack {
                    Text("Cancelled").foregroundStyle(.secondary)
                    Spacer()
                    Button(action: retry) { Text("Retry") }.buttonStyle(.link)
                }
                .font(.caption)
            }
        }
    }
}
