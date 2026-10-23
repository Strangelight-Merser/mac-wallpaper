import AppKit
import Observation
import WELibrary
import WESteam

/// Wallpaper Engine's `assets` folder for the app: a folder the user chose (from a Windows PC), or our own
/// copy downloaded from their Steam account. Downloads only ever start after the size was shown.
@MainActor
@Observable
final class AssetsModel {
    private(set) var manager: AssetsManager
    var sheetShown = false
    /// Called when the folder scenes should use changes (reload the wallpaper, re-check the library).
    var locationChanged: () -> Void = {}
    private let connection: SteamConnection
    private var task: Task<Void, Never>?

    init(connection: SteamConnection) {
        self.connection = connection
        manager = Self.makeManager(connection: connection)
    }

    /// The folder scenes use right now: a valid chosen folder first, else our download, else none.
    nonisolated static var currentLocation: URL? {
        if let path = UserDefaults.standard.string(forKey: "assets") {
            let url = URL(fileURLWithPath: path)
            if AssetsManager.validFolder(url) { return url }
        }
        let downloaded = AssetsManager.defaultLocation
        return AssetsManager.validFolder(downloaded) ? downloaded : nil
    }

    var isInstalled: Bool { if case .installed = manager.status { true } else { false } }
    var usesChosenFolder: Bool { UserDefaults.standard.string(forKey: "assets") != nil }

    private static func makeManager(connection: SteamConnection) -> AssetsManager {
        let chosen = UserDefaults.standard.string(forKey: "assets").map { URL(fileURLWithPath: $0) }
        return AssetsManager(userFolder: chosen, steam: ConnectionAssetsAccess(connection: connection))
    }

    func refresh() async { await manager.refresh() }

    /// Asks Steam for the size (metadata only, about 1–3 MB).
    func checkSize() {
        run { [manager] in _ = try? await manager.plan() }
    }

    func download() {
        guard let plan = manager.plannedDownload else { return }
        // Allow retries on top of the planned bytes, as workshop downloads do.
        let limit = plan.networkBytes * 2 + 1_048_576
        run { [manager] in
            do { try await manager.download(maxBytes: limit) } catch { return }
            self.locationChanged()
        }
    }

    func checkForUpdate() { run { [manager] in await manager.checkForUpdate() } }

    func installUpdate() {
        run { [manager] in
            do { try await manager.installUpdate() } catch { return }
            self.locationChanged()
        }
    }

    func cancel() { manager.cancel() }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = String(localized: "Choose Wallpaper Engine's “assets” folder")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard AssetsManager.validFolder(url) else {
            let alert = NSAlert()
            alert.messageText = String(localized: "This isn’t Wallpaper Engine’s “assets” folder")
            alert.informativeText = String(localized: "Choose the folder named “assets” inside Wallpaper Engine’s installation folder. It contains folders such as “shaders”, “materials” and “effects”.")
            alert.runModal()
            return
        }
        UserDefaults.standard.set(url.path, forKey: "assets")
        rebuild()
    }

    /// Stop using a chosen folder; scenes use our Steam download (if there is one).
    func useDownloadedCopy() {
        UserDefaults.standard.removeObject(forKey: "assets")
        rebuild()
    }

    private func rebuild() {
        manager = Self.makeManager(connection: connection)
        Task { await manager.refresh(); locationChanged() }
    }

    private func run(_ body: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task { await body() }
    }

    /// What went wrong, for the user.
    static func message(_ failure: AssetsFailure) -> String {
        switch failure {
        case .unsupportedCompression: String(localized: "Steam sent files in a format this version can’t unpack yet.")
        case .accessDenied: String(localized: "Steam didn’t allow the download. Make sure this account owns Wallpaper Engine.")
        case .authentication: String(localized: "Your Steam login has expired. Log in again.")
        case .network: String(localized: "Couldn’t reach Steam. Check your internet connection and try again.")
        case .byteLimit: String(localized: "The download turned out larger than shown, so it was stopped.")
        case .invalidFolder: String(localized: "This folder doesn’t look like Wallpaper Engine’s “assets” folder.")
        case .invalidReceipt: String(localized: "The downloaded files are incomplete. Download them again.")
        case .busy: String(localized: "Already working on it.")
        case .noUpdate, .noPlan: String(localized: "Check the download size first.")
        case .userFolder: String(localized: "You’re using a folder you chose, so nothing is downloaded.")
        case .steam(let error): SteamModel.message(error)
        case .fileSystem(let code): String(localized: "Couldn’t write the files (error \(code)).")
        case .unknown: String(localized: "Something went wrong.")
        }
    }
}

/// Runs the assets downloader on the app's shared Steam connection (reconnecting if Steam drops it).
struct ConnectionAssetsAccess: AssetsSteamAccess, @unchecked Sendable {
    let connection: SteamConnection

    func plan() async throws -> WEAssetsPlan {
        try await connection.run { client, session in
            try await WEAssetsDownloader(client: client, session: session).plan()
        }
    }

    func download(_ plan: WEAssetsPlan, to destination: URL, maxBytes: Int64,
                  progress: @Sendable (DownloadProgress) -> Void) async throws {
        try await withoutActuallyEscaping(progress) { progress in
            try await connection.run { client, session in
                _ = try await WEAssetsDownloader(client: client, session: session)
                    .download(plan, to: destination, maxBytes: maxBytes, progress: progress)
            }
        }
    }

    func checkForUpdate(receiptAt folder: URL) async throws -> WEAssetsUpdate {
        try await connection.run { client, session in
            try await WEAssetsDownloader(client: client, session: session).checkForUpdate(receiptAt: folder)
        }
    }
}
