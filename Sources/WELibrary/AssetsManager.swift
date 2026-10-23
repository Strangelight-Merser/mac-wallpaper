import Darwin
import Foundation
import Observation
import WESteam

public enum AssetsFailure: Error, Sendable, Equatable {
    case unsupportedCompression(String)
    case accessDenied
    case authentication
    case network
    case byteLimit(Int64)
    case invalidFolder
    case invalidReceipt
    case busy
    case noUpdate
    case noPlan
    case userFolder
    case steam(SteamError)
    case fileSystem(code: Int)
    case unknown

    public static func cause(of error: Error) -> Self {
        if let failure = error as? Self { return failure }
        if let error = error as? SteamError {
            switch error {
            case .unsupportedCompression(let format): return .unsupportedCompression(format)
            case .result(9), .result(15), .http(401), .http(403): return .accessDenied
            case .expired, .invalidToken, .result(5), .result(27): return .authentication
            case .transport, .timeout, .disconnected, .http: return .network
            case .tooLarge(let bytes): return .byteLimit(bytes)
            default: return .steam(error)
            }
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return .network }
        if ns.domain == NSCocoaErrorDomain || ns.domain == NSPOSIXErrorDomain { return .fileSystem(code: ns.code) }
        return .unknown
    }
}

public enum AssetsStatus: Sendable, Equatable {
    public enum Source: Sendable, Equatable { case downloaded, userFolder }
    case missing
    case installed(location: URL, source: Source, buildID: UInt64?)
    case checking
    case updateAvailable(location: URL, changedBytes: Int64, changedDiskBytes: Int64)
    case downloading(doneBytes: Int64, totalBytes: Int64, files: Int, totalFiles: Int)
    case failed(AssetsFailure)
}

public protocol AssetsSteamAccess: Sendable {
    func plan() async throws -> WEAssetsPlan
    /// Must write the downloader's sibling receipt before returning successfully.
    func download(_ plan: WEAssetsPlan, to: URL, maxBytes: Int64,
                  progress: @Sendable (DownloadProgress) -> Void) async throws
    func checkForUpdate(receiptAt: URL) async throws -> WEAssetsUpdate
}

/// Adapts an authenticated shared Steam session's downloader without owning login state.
public struct DownloaderAssetsSteamAccess: AssetsSteamAccess {
    private let downloader: WEAssetsDownloader
    public init(_ downloader: WEAssetsDownloader) { self.downloader = downloader }
    public func plan() async throws -> WEAssetsPlan { try await downloader.plan() }
    public func download(_ plan: WEAssetsPlan, to: URL, maxBytes: Int64,
                         progress: @Sendable (DownloadProgress) -> Void) async throws {
        _ = try await downloader.download(plan, to: to, maxBytes: maxBytes, progress: progress)
    }
    public func checkForUpdate(receiptAt: URL) async throws -> WEAssetsUpdate {
        try await downloader.checkForUpdate(receiptAt: receiptAt)
    }
}

@MainActor @Observable public final class AssetsManager {
    public private(set) var status: AssetsStatus = .missing
    public private(set) var location: URL?
    public private(set) var plannedDownload: WEAssetsPlan?
    public private(set) var availableUpdate: WEAssetsUpdate?
    public nonisolated static var defaultLocation: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacWallpaper/WEAssets/assets", isDirectory: true)
    }
    private let destination: URL
    private let userFolder: URL?
    private let steam: any AssetsSteamAccess
    private var busy = false
    private var downloadTask: Task<Void, Error>?

    public init(defaultLocation: URL = AssetsManager.defaultLocation, userFolder: URL?, steam: any AssetsSteamAccess) {
        destination = defaultLocation.standardizedFileURL
        self.userFolder = userFolder?.standardizedFileURL
        self.steam = steam
    }

    public func refresh() async {
        guard !busy else { return }
        detect()
    }

    private func detect() {
        location = nil
        if let userFolder {
            guard Self.validFolder(userFolder) else { status = .failed(.invalidFolder); return }
            location = userFolder
            status = .installed(location: userFolder, source: .userFolder, buildID: nil)
            return
        }
        guard FileManager.default.fileExists(atPath: destination.path) else { status = .missing; return }
        guard Self.validFolder(destination) else { status = .failed(.invalidFolder); return }
        guard let receipt = try? Self.receipt(at: destination) else { status = .failed(.invalidReceipt); return }
        location = destination
        status = .installed(location: destination, source: .downloaded, buildID: receipt.buildID)
    }

    public func plan() async throws -> WEAssetsPlan {
        guard !busy else { throw AssetsFailure.busy }
        busy = true
        defer { busy = false }
        status = .checking
        do {
            let plan = try await steam.plan()
            try Task.checkCancellation()
            plannedDownload = plan
            detect()
            return plan
        } catch {
            report(error)
            throw error
        }
    }

    public func download(maxBytes: Int64) async throws {
        guard !busy else { throw AssetsFailure.busy }
        guard userFolder == nil else { throw AssetsFailure.userFolder }
        // A plan must be shown before authorizing content; this method never silently replans.
        guard let plan = plannedDownload else { throw AssetsFailure.noPlan }
        try await install(plan, maxBytes: maxBytes)
    }

    public func cancel() { downloadTask?.cancel() }

    public func checkForUpdate() async {
        guard !busy else { return }
        detect()
        guard userFolder == nil, location != nil else { return }
        busy = true
        defer { busy = false }
        availableUpdate = nil
        status = .checking
        do {
            let update = try await steam.checkForUpdate(receiptAt: destination)
            try Task.checkCancellation()
            availableUpdate = update
            switch update {
            case .upToDate: detect()
            case .available(_, let bytes, let disk):
                status = .updateAvailable(location: destination, changedBytes: bytes, changedDiskBytes: disk)
            }
        } catch { report(error) }
    }

    /// Explicit approval of the most recently displayed changed-byte size.
    public func installUpdate() async throws {
        guard !busy else { throw AssetsFailure.busy }
        guard userFolder == nil else { throw AssetsFailure.userFolder }
        guard case .available(let plan, let bytes, _) = availableUpdate else { throw AssetsFailure.noUpdate }
        try await install(plan, maxBytes: bytes)
    }

    private func install(_ plan: WEAssetsPlan, maxBytes: Int64) async throws {
        busy = true
        defer { busy = false; downloadTask = nil }
        let task = Task { try await self.performInstall(plan, maxBytes: maxBytes) }
        downloadTask = task
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            availableUpdate = nil
            plannedDownload = nil
            detect()
        } catch {
            report(error)
            throw error
        }
    }

    private func performInstall(_ plan: WEAssetsPlan, maxBytes: Int64) async throws {
        try Task.checkCancellation()
        guard maxBytes >= 0 else { throw AssetsFailure.byteLimit(plan.networkBytes) }
        let fm = FileManager.default
        let staging = URL(fileURLWithPath: destination.path + ".staging", isDirectory: true)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: staging.path), fm.fileExists(atPath: destination.path) {
            try fm.copyItem(at: destination, to: staging)
        }
        let (stream, continuation) = AsyncStream<DownloadProgress>.makeStream()
        let observer = Task { @MainActor in
            for await progress in stream {
                status = .downloading(doneBytes: progress.networkBytesDone, totalBytes: progress.networkBytesTotal,
                                      files: progress.filesDone, totalFiles: progress.filesTotal)
            }
        }
        do {
            try await steam.download(plan, to: staging, maxBytes: maxBytes) { continuation.yield($0) }
            continuation.finish()
            await observer.value
            try Task.checkCancellation()
            guard Self.validFolder(staging) else { throw AssetsFailure.invalidFolder }
            guard let receipt = try? Self.receipt(at: staging), receipt.buildID == plan.buildID,
                  receipt.depots == plan.depots else {
                throw AssetsFailure.invalidReceipt
            }
            let receiptData = try Data(contentsOf: WEAssetsDownloader.receiptURL(for: staging))
            let exists = fm.fileExists(atPath: destination.path)
            if exists { try Self.swap(staging, destination) }
            else { try fm.moveItem(at: staging, to: destination) }
            do {
                try receiptData.write(to: WEAssetsDownloader.receiptURL(for: destination), options: .atomic)
            } catch {
                if exists { try Self.swap(staging, destination) }
                else { try fm.moveItem(at: destination, to: staging) }
                throw error
            }
            // Publication succeeded. Cleanup cannot turn a committed installation into a failure.
            try? fm.removeItem(at: staging)
            try? fm.removeItem(at: WEAssetsDownloader.receiptURL(for: staging))
        } catch {
            continuation.finish()
            await observer.value
            throw error
        }
    }

    private func report(_ error: Error) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { detect() }
        else { status = .failed(AssetsFailure.cause(of: error)) }
    }

    private static func receipt(at folder: URL) throws -> WEAssetsReceipt {
        try JSONDecoder().decode(WEAssetsReceipt.self, from: Data(contentsOf: WEAssetsDownloader.receiptURL(for: folder)))
    }

    public nonisolated static func validFolder(_ folder: URL) -> Bool {
        guard folder.isFileURL else { return false }
        for path in ["shaders", "materials", "effects"] {
            guard (try? folder.appendingPathComponent(path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
        }
        for path in ["shaders/genericimage2.frag", "materials/util/composelayer.json"] {
            guard (try? folder.appendingPathComponent(path).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return false }
        }
        return true
    }

    private static func swap(_ first: URL, _ second: URL) throws {
        guard renamex_np(first.path, second.path, UInt32(RENAME_SWAP)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
