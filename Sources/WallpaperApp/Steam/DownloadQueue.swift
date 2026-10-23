import Foundation
import Observation
import WELibrary
import WESteam

/// Workshop downloads, one at a time over a shared Steam connection, into the app's download folder.
@MainActor
@Observable
final class DownloadQueue {
    struct Download: Identifiable {
        enum State: Equatable {
            case queued, preparing
            case downloading(done: Int64, total: Int64)
            case finished
            case failed(String)
            case cancelled
        }
        let item: WorkshopItem
        var state: State = .queued
        var id: UInt64 { item.id }
        var isActive: Bool {
            switch state { case .queued, .preparing, .downloading: true; default: false }
        }
    }

    private(set) var downloads: [Download] = []
    let library: LibraryModel
    private let connection: SteamConnection
    private var runner: Task<Void, Never>?
    private var current: (id: UInt64, task: Task<Void, Error>)?

    init(library: LibraryModel, connection: SteamConnection) { self.library = library; self.connection = connection }

    var activeCount: Int { downloads.filter(\.isActive).count }
    /// 0…1 over the active downloads (finished ones count as done).
    var progress: Double {
        let relevant = downloads.filter { $0.isActive || $0.state == .finished }
        guard !relevant.isEmpty else { return 0 }
        let total = relevant.reduce(0.0) { $0 + Double(max(1, $1.item.fileSize)) }
        let done = relevant.reduce(0.0) { sum, d in
            switch d.state {
            case .finished: sum + Double(max(1, d.item.fileSize))
            case .downloading(let done, let all) where all > 0: sum + Double(d.item.fileSize) * Double(done) / Double(all)
            default: sum
            }
        }
        return done / total
    }

    func contains(_ id: UInt64) -> Bool { downloads.contains { $0.id == id && $0.state != .cancelled } }

    func enqueue(_ items: [WorkshopItem]) {
        for item in items where !downloads.contains(where: { $0.id == item.id && $0.isActive }) {
            downloads.removeAll { $0.id == item.id }
            downloads.append(Download(item: item))
        }
        if runner == nil { runner = Task { await run() } }
    }

    func cancel(_ id: UInt64) {
        if current?.id == id { current?.task.cancel() }
        if let i = downloads.firstIndex(where: { $0.id == id }), downloads[i].isActive { downloads[i].state = .cancelled }
    }

    func clearFinished() { downloads.removeAll { !$0.isActive } }

    /// Queues a failed or cancelled item again; files already verified in its staging folder are kept.
    func retry(_ id: UInt64) {
        guard let item = downloads.first(where: { $0.id == id && !$0.isActive && $0.state != .finished })?.item else { return }
        enqueue([item])
    }

    private func run() async {
        while let index = downloads.firstIndex(where: { $0.state == .queued }) {
            let item = downloads[index].item
            let task = Task { try await download(item) }
            current = (item.id, task)
            do {
                try await task.value
                set(item.id, .finished)
                log("workshop \(item.id) downloaded")
                await library.refresh()
            } catch is CancellationError {
                set(item.id, .cancelled)
                log("workshop \(item.id) cancelled")
            } catch {
                set(item.id, .failed(SteamModel.message(error)))
                log("workshop \(item.id) failed: \(error)")
            }
            current = nil
        }
        runner = nil
    }

    /// Retried on a fresh session if Steam drops the current one; verified files from the previous
    /// attempt stay in the staging folder and are not downloaded again.
    private func download(_ item: WorkshopItem) async throws {
        set(item.id, .preparing)
        try await connection.run { client, session in
            try await self.download(item, client: client, session: session)
        }
    }

    private func download(_ item: WorkshopItem, client: SteamCMClient, session: SteamSession) async throws {
        let downloader = WorkshopDownloader(client: client, session: session)
        let plan = try await downloader.plan(item)
        let dest = LibraryRoots.downloads.url.appendingPathComponent(String(item.id), isDirectory: true)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        set(item.id, .downloading(done: 0, total: plan.networkBytes))
        // The user chose this item with its size shown; allow retries on top of the planned bytes.
        let limit = plan.networkBytes * 2 + 1_048_576
        _ = try await downloader.download(plan, to: dest, maxBytes: limit) { progress in
            Task { @MainActor in
                self.set(item.id, .downloading(done: progress.networkBytesDone, total: progress.networkBytesTotal))
            }
        }
    }

    private func set(_ id: UInt64, _ state: Download.State) {
        guard let i = downloads.firstIndex(where: { $0.id == id }) else { return }
        // Late progress updates must not overwrite a final state.
        if case .downloading = state, !downloads[i].isActive { return }
        downloads[i].state = state
    }
}
