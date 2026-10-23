import Foundation
import XCTest
import WELibrary
@testable import WESteam

private func assetsPlan(build: UInt64 = 1) throws -> WEAssetsPlan {
    let chunk = ContentManifest.Chunk(sha: Data(repeating: 1, count: 20), crc: 0, offset: 0,
                                      originalSize: 20, compressedSize: 10)
    let file = ContentManifest.File(path: "shaders/genericimage2.frag", size: 20, flags: 0,
                                   shaFilename: Data(), shaContent: Data(repeating: UInt8(build), count: 20),
                                   chunks: [chunk], linkTarget: "")
    let manifest = ContentManifest(depotID: 1, manifestID: build, files: [file])
    return try WEAssetsPlan(buildID: build, content: [ContentDepot(manifest: manifest, key: Data(), servers: [])])
}

private func makeAssets(_ folder: URL, build: UInt64 = 1, receipt: Bool = true) throws {
    let fm = FileManager.default
    for path in ["shaders", "materials/util", "effects"] {
        try fm.createDirectory(at: folder.appendingPathComponent(path), withIntermediateDirectories: true)
    }
    for path in ["shaders/genericimage2.frag", "materials/util/composelayer.json"] {
        try Data("build-\(build)".utf8).write(to: folder.appendingPathComponent(path))
    }
    if receipt {
        try JSONEncoder().encode(WEAssetsReceipt(assetsPlan(build: build)))
            .write(to: WEAssetsDownloader.receiptURL(for: folder))
    }
}

private actor FakeAssetsSteam: AssetsSteamAccess {
    var nextPlan: WEAssetsPlan
    var update: WEAssetsUpdate = .upToDate
    var failure: SteamError?
    var suspended = false
    var invalid = false
    var downloads = 0
    var checks = 0
    var started = false
    var requestedLimit: Int64?
    var reused = false
    init() throws { nextPlan = try assetsPlan() }
    func configure(update: WEAssetsUpdate = .upToDate, failure: SteamError? = nil,
                   suspended: Bool = false, invalid: Bool = false) {
        self.update = update; self.failure = failure; self.suspended = suspended; self.invalid = invalid
    }
    func plan() async throws -> WEAssetsPlan { nextPlan }
    func checkForUpdate(receiptAt: URL) async throws -> WEAssetsUpdate {
        checks += 1
        if let failure { throw failure }
        return update
    }
    func download(_ plan: WEAssetsPlan, to: URL, maxBytes: Int64,
                  progress: @Sendable (DownloadProgress) -> Void) async throws {
        downloads += 1; requestedLimit = maxBytes
        reused = FileManager.default.fileExists(atPath: to.appendingPathComponent("shaders/genericimage2.frag").path)
        guard maxBytes >= 10 else { throw SteamError.tooLarge(10) }
        progress(.init(networkBytesDone: 0, networkBytesTotal: 10, filesDone: 0, filesTotal: 1))
        progress(.init(networkBytesDone: 5, networkBytesTotal: 10, filesDone: 0, filesTotal: 1))
        started = true
        if suspended { try await Task.sleep(for: .seconds(60)) }
        if let failure { throw failure }
        if !invalid { try makeAssets(to, build: plan.buildID) }
        progress(.init(networkBytesDone: 10, networkBytesTotal: 10, filesDone: 1, filesTotal: 1))
    }
}

final class AssetsManagerTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @MainActor func testMissingPlanDownloadAndReceipt() async throws {
        let fake = try FakeAssetsSteam()
        let dest = root.appendingPathComponent("assets", isDirectory: true)
        let manager = AssetsManager(defaultLocation: dest, userFolder: nil, steam: fake)
        await manager.refresh()
        XCTAssertEqual(manager.status, .missing)
        let plan = try await manager.plan()
        XCTAssertEqual(plan.networkBytes, 10)
        XCTAssertEqual(plan.diskBytes, 20)
        XCTAssertEqual(plan.files, 1)
        let before = await fake.downloads
        XCTAssertEqual(before, 0)
        try await manager.download(maxBytes: 10)
        XCTAssertEqual(manager.status, .installed(location: dest, source: .downloaded, buildID: 1))
        XCTAssertEqual(manager.location, dest)
        let receipt = try JSONDecoder().decode(WEAssetsReceipt.self,
            from: Data(contentsOf: WEAssetsDownloader.receiptURL(for: dest)))
        XCTAssertEqual(receipt.buildID, 1)
        let restarted = AssetsManager(defaultLocation: dest, userFolder: nil, steam: fake)
        await restarted.refresh()
        XCTAssertEqual(restarted.status, manager.status)
    }

    @MainActor func testProgressCancelAndRetryPreserveInstallation() async throws {
        let fake = try FakeAssetsSteam()
        await fake.configure(suspended: true)
        let dest = root.appendingPathComponent("assets", isDirectory: true)
        try makeAssets(dest, build: 2)
        let original = try Data(contentsOf: WEAssetsDownloader.receiptURL(for: dest))
        let manager = AssetsManager(defaultLocation: dest, userFolder: nil, steam: fake)
        await manager.refresh()
        _ = try await manager.plan()
        let task = Task { try await manager.download(maxBytes: 10) }
        for _ in 0..<10000 {
            if manager.status == .downloading(doneBytes: 5, totalBytes: 10, files: 0, totalFiles: 1) { break }
            await Task.yield()
        }
        XCTAssertEqual(manager.status, .downloading(doneBytes: 5, totalBytes: 10, files: 0, totalFiles: 1))
        XCTAssertEqual(manager.location, dest)
        do { _ = try await manager.plan(); XCTFail("overlapping plan") } catch { XCTAssertEqual(error as? AssetsFailure, .busy) }
        manager.cancel()
        do { try await task.value; XCTFail("cancelled download succeeded") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: WEAssetsDownloader.receiptURL(for: dest)), original)
        XCTAssertEqual(manager.status, .installed(location: dest, source: .downloaded, buildID: 2))
        await fake.configure()
        try await manager.download(maxBytes: 10)
        XCTAssertEqual(manager.status, .installed(location: dest, source: .downloaded, buildID: 1))
    }

    @MainActor func testUpdateMetadataAndInstall() async throws {
        let fake = try FakeAssetsSteam()
        let dest = root.appendingPathComponent("assets", isDirectory: true)
        try makeAssets(dest)
        let manager = AssetsManager(defaultLocation: dest, userFolder: nil, steam: fake)
        await manager.checkForUpdate()
        XCTAssertEqual(manager.status, .installed(location: dest, source: .downloaded, buildID: 1))
        await fake.configure(update: .available(plan: try assetsPlan(build: 2), changedBytes: 10, changedDiskBytes: 20))
        await manager.checkForUpdate()
        XCTAssertEqual(manager.status, .updateAvailable(location: dest, changedBytes: 10, changedDiskBytes: 20))
        let downloads = await fake.downloads
        XCTAssertEqual(downloads, 0)
        try await manager.installUpdate()
        XCTAssertEqual(manager.status, .installed(location: dest, source: .downloaded, buildID: 2))
        let limit = await fake.requestedLimit
        let reused = await fake.reused
        XCTAssertEqual(limit, 10)
        XCTAssertTrue(reused)
    }

    @MainActor func testFailureLeavesOldInstallationAndMapsCauses() async throws {
        let fake = try FakeAssetsSteam()
        let dest = root.appendingPathComponent("assets", isDirectory: true)
        try makeAssets(dest, build: 2)
        let manager = AssetsManager(defaultLocation: dest, userFolder: nil, steam: fake)
        await manager.refresh()
        _ = try await manager.plan()
        for (error, cause) in [(SteamError.unsupportedCompression("zstd"), AssetsFailure.unsupportedCompression("zstd")),
                               (.result(9), .accessDenied), (.result(15), .accessDenied), (.timeout, .network)] {
            await fake.configure(failure: error)
            do { try await manager.download(maxBytes: 10); XCTFail("expected failure") } catch {}
            XCTAssertEqual(manager.status, .failed(cause))
            XCTAssertEqual(manager.location, dest)
            XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("shaders/genericimage2.frag")), "build-2")
        }
        XCTAssertEqual(AssetsFailure.cause(of: URLError(.notConnectedToInternet)), .network)
        await fake.configure()
        do { try await manager.download(maxBytes: 0); XCTFail("expected budget failure") } catch {}
        XCTAssertEqual(manager.status, .failed(.byteLimit(10)))
    }

    @MainActor func testUserFolderValidationAndPrecedence() async throws {
        let fake = try FakeAssetsSteam()
        let dest = root.appendingPathComponent("assets", isDirectory: true)
        let user = root.appendingPathComponent("user", isDirectory: true)
        try makeAssets(dest)
        try makeAssets(user, receipt: false)
        let manager = AssetsManager(defaultLocation: dest, userFolder: user, steam: fake)
        await manager.refresh()
        XCTAssertEqual(manager.status, .installed(location: user, source: .userFolder, buildID: nil))
        await manager.checkForUpdate()
        let checks = await fake.checks
        XCTAssertEqual(checks, 0)
        do { try await manager.download(maxBytes: 10); XCTFail("user folder download") } catch {
            XCTAssertEqual(error as? AssetsFailure, .userFolder)
        }
        try FileManager.default.removeItem(at: user.appendingPathComponent("shaders/genericimage2.frag"))
        await manager.refresh()
        XCTAssertNil(manager.location)
        XCTAssertEqual(manager.status, .failed(.invalidFolder))
        XCTAssertFalse(AssetsManager.validFolder(root))
    }

    @MainActor func testInvalidDownloadAndReceiptRejected() async throws {
        let fake = try FakeAssetsSteam()
        await fake.configure(invalid: true)
        let dest = root.appendingPathComponent("assets", isDirectory: true)
        let manager = AssetsManager(defaultLocation: dest, userFolder: nil, steam: fake)
        _ = try await manager.plan()
        do { try await manager.download(maxBytes: 10); XCTFail("invalid download") } catch {}
        XCTAssertEqual(manager.status, .failed(.invalidFolder))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        try makeAssets(dest, receipt: false)
        await manager.refresh()
        XCTAssertEqual(manager.status, .failed(.invalidReceipt))
        XCTAssertNil(manager.location)
    }
    @MainActor func testParentCancellationPreservesInstallation() async throws {
        let fake = try FakeAssetsSteam()
        await fake.configure(suspended: true)
        let dest = root.appendingPathComponent("assets", isDirectory: true)
        try makeAssets(dest, build: 2)
        let manager = AssetsManager(defaultLocation: dest, userFolder: nil, steam: fake)
        _ = try await manager.plan()
        let task = Task { try await manager.download(maxBytes: 10) }
        while !(await fake.started) { await Task.yield() }
        task.cancel()
        do { try await task.value; XCTFail("parent cancellation ignored") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(manager.status, .installed(location: dest, source: .downloaded, buildID: 2))
    }

    @MainActor func testReceiptPublicationFailureRollsBackDirectory() async throws {
        let fake = try FakeAssetsSteam()
        let dest = root.appendingPathComponent("assets", isDirectory: true)
        try makeAssets(dest, build: 2, receipt: false)
        let blockedReceipt = WEAssetsDownloader.receiptURL(for: dest)
        try FileManager.default.createDirectory(at: blockedReceipt, withIntermediateDirectories: true)
        let manager = AssetsManager(defaultLocation: dest, userFolder: nil, steam: fake)
        _ = try await manager.plan()
        do { try await manager.download(maxBytes: 10); XCTFail("receipt write should fail") } catch {}
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("shaders/genericimage2.frag")), "build-2")
    }

    @MainActor func testRepositoryUserAssetsWhenAvailable() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let folder = repo.appendingPathComponent("samples/wallpaper_engine/assets", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { throw XCTSkip("Local WE assets not present") }
        XCTAssertTrue(AssetsManager.validFolder(folder))
    }

}
