import Foundation
import XCTest
@testable import WELibrary

private actor CheckCounter {
    var count = 0
    func check(deep: Bool) -> Compatibility {
        count += 1
        return Compatibility(status: .supported, notes: ["check \(count)"], checkedDeep: deep)
    }
}

final class IndexTests: LibraryTestCase {
    func testIncrementalPersistenceAndInvalidation() async throws {
        let folder = try project("root/one", type: "web")
        let root = LibraryRoot(url: folder.deletingLastPathComponent(), kind: .downloads)
        let index = temporary.appendingPathComponent("library.json")
        let counter = CheckCounter()
        let check: WallpaperLibrary.Check = { _, _, deep in await counter.check(deep: deep) }
        let library = WallpaperLibrary(indexURL: index, checker: check)
        let first = await library.refresh(roots: [root], assets: nil, deep: false)
        XCTAssertEqual(first.added.count, 1)
        let entries = await library.entries()
        let second = await library.refresh(roots: [root], assets: nil, deep: false)
        XCTAssertEqual(second.added, []); XCTAssertEqual(second.updated, []); XCTAssertEqual(second.removed, [])
        var count = await counter.count; XCTAssertEqual(count, 1)
        let reopened = WallpaperLibrary(indexURL: index, checker: check)
        let persisted = await reopened.entries(); XCTAssertEqual(persisted, entries)
        _ = await reopened.refresh(roots: [root], assets: nil, deep: false)
        count = await counter.count; XCTAssertEqual(count, 1)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)], ofItemAtPath: folder.appendingPathComponent("project.json").path)
        let changed = await reopened.refresh(roots: [root], assets: nil, deep: false)
        XCTAssertEqual(changed.updated.count, 1)
        count = await counter.count; XCTAssertEqual(count, 2)
        let bumped = WallpaperLibrary(indexURL: index, checkerVersion: CompatibilityChecker.version + 1, checker: check)
        _ = await bumped.refresh(roots: [root], assets: nil, deep: false)
        count = await counter.count; XCTAssertEqual(count, 3)
        let assets = temporary.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets.appendingPathComponent("shaders"), withIntermediateDirectories: true)
        _ = await bumped.refresh(roots: [root], assets: assets, deep: false)
        count = await counter.count; XCTAssertEqual(count, 4)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000_000_001)], ofItemAtPath: assets.appendingPathComponent("shaders").path)
        _ = await bumped.refresh(roots: [root], assets: assets, deep: false)
        count = await counter.count; XCTAssertEqual(count, 5)
        try FileManager.default.removeItem(at: folder)
        let removed = await bumped.refresh(roots: [root], assets: assets, deep: false)
        XCTAssertEqual(removed.removed, first.added)
        let remaining = await bumped.entries(); XCTAssertTrue(remaining.isEmpty)
    }

    func testDuplicateIDsAndBadIndex() async throws {
        _ = try project("root/one", extra: ["workshopid": "123"])
        _ = try project("root/two", extra: ["workshopid": 123])
        let root = LibraryRoot(url: temporary.appendingPathComponent("root"), kind: .userFolder)
        let index = try write("library.json", "not json")
        let library = WallpaperLibrary(indexURL: index)
        XCTAssertEqual(try String(contentsOf: index.appendingPathExtension("bad"), encoding: .utf8), "not json")
        _ = await library.refresh(roots: [root], assets: nil, deep: false)
        let entries = await library.entries()
        XCTAssertEqual(entries.map(\.id), ["ws:123", "ws:123#2"])
        XCTAssertNil(entries[0].duplicateOf); XCTAssertEqual(entries[1].duplicateOf, "ws:123")
        let restored = await WallpaperLibrary(indexURL: index).entries()
        XCTAssertEqual(restored, entries)
    }

    func testDeepUpgradeAndCancellation() async throws {
        _ = try project("root/one"); _ = try project("root/two")
        let root = LibraryRoot(url: temporary.appendingPathComponent("root"), kind: .downloads)
        let counter = CheckCounter()
        let library = WallpaperLibrary(indexURL: temporary.appendingPathComponent("library.json"), checker: { _, _, deep in await counter.check(deep: deep) })
        _ = await library.refresh(roots: [root], assets: nil, deep: false)
        _ = await library.refresh(roots: [root], assets: nil, deep: true)
        _ = await library.refresh(roots: [root], assets: nil, deep: true)
        var count = await counter.count; XCTAssertEqual(count, 4)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await library.refresh(roots: [], assets: nil, deep: true)
        }
        let diff = await task.value
        XCTAssertTrue(diff.cancelled)
        let entries = await library.entries(); XCTAssertEqual(entries.count, 2)
        count = await counter.count; XCTAssertEqual(count, 4)
    }
}

private actor CheckGate {
    var count = 0
    var blocked: CheckedContinuation<Void, Never>?
    var observers: [CheckedContinuation<Void, Never>] = []

    func check() async -> Compatibility {
        count += 1
        if count == 1 {
            await withCheckedContinuation { continuation in
                blocked = continuation
                observers.forEach { $0.resume() }; observers = []
            }
        }
        return Compatibility(status: .supported, checkedDeep: true)
    }

    func waitForCheck() async {
        if blocked == nil { await withCheckedContinuation { observers.append($0) } }
    }

    func release() { blocked?.resume(); blocked = nil }
}

extension IndexTests {
    func testCancellationBetweenWallpapersPreservesIndex() async throws {
        _ = try project("root/one"); _ = try project("root/two")
        let root = LibraryRoot(url: temporary.appendingPathComponent("root"), kind: .downloads)
        let index = temporary.appendingPathComponent("index.json")
        let gate = CheckGate()
        let library = WallpaperLibrary(indexURL: index, checker: { _, _, _ in await gate.check() })
        let task = Task { await library.refresh(roots: [root], assets: nil, deep: true) }
        await gate.waitForCheck()
        task.cancel()
        await gate.release()
        let result = await task.value
        let count = await gate.count
        XCTAssertTrue(result.cancelled); XCTAssertEqual(count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: index.path))
        let entries = await library.entries(); XCTAssertTrue(entries.isEmpty)
    }

    func testConcurrentRefreshesReuseResults() async throws {
        _ = try project("root/one")
        let root = LibraryRoot(url: temporary.appendingPathComponent("root"), kind: .downloads)
        let gate = CheckGate()
        let library = WallpaperLibrary(indexURL: temporary.appendingPathComponent("index.json"), checker: { _, _, _ in await gate.check() })
        let first = Task { await library.refresh(roots: [root], assets: nil, deep: true) }
        await gate.waitForCheck()
        let second = Task { await library.refresh(roots: [root], assets: nil, deep: true) }
        await gate.release()
        let firstResult = await first.value, secondResult = await second.value
        let count = await gate.count
        XCTAssertEqual(firstResult.added.count, 1); XCTAssertTrue(secondResult.added.isEmpty)
        XCTAssertEqual(count, 1)
    }
}
