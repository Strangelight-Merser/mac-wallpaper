import Foundation
import XCTest
import WESteam
@testable import WELibrary

final class SubscriptionSyncTests: LibraryTestCase {
    func testPlan() throws {
        for id in 1...5 {
            try json("downloads/\(id)/.steam-manifest.json", ["publishedFileID": id, "manifestID": 10, "timeUpdated": 100, "files": 1, "bytes": 4])
        }
        _ = try project("downloads/8", type: "web")
        try json("downloads/.previous/99/.steam-manifest.json", ["publishedFileID": 99, "manifestID": 10, "timeUpdated": 100])
        try json("outside/.steam-manifest.json", ["publishedFileID": 98, "manifestID": 10, "timeUpdated": 100])
        try FileManager.default.createSymbolicLink(at: temporary.appendingPathComponent("downloads/98"),
                                                   withDestinationURL: temporary.appendingPathComponent("outside"))
        let items = [item(1), item(2, manifest: 11), item(3, time: 101), item(4, result: 9), item(6), item(7), item(8), item(9, result: 9)]
        let plan = try SubscriptionSync.plan(subscribed: items, downloads: temporary.appendingPathComponent("downloads"), declined: [2, 7])
        XCTAssertEqual(plan.new.map(\.id), [6, 8])
        XCTAssertEqual(plan.updated.map { $0.item.id }, [2, 3])
        XCTAssertEqual(plan.updated.map(\.localManifest), [10, 10])
        XCTAssertEqual(plan.updated.first?.localTimeUpdated, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(plan.unsubscribed, [5])
        XCTAssertEqual(plan.unchanged, 1)
    }

    func testMissingRootAndMalformedReceipt() throws {
        let root = temporary.appendingPathComponent("downloads")
        XCTAssertEqual(try SubscriptionSync.plan(subscribed: [item(1)], downloads: root, declined: []).new.count, 1)
        try write("downloads/1/.steam-manifest.json", "broken")
        XCTAssertThrowsError(try SubscriptionSync.plan(subscribed: [], downloads: root, declined: []))
    }

    func testEqualBetterAndRollback() async throws {
        let root = temporary.appendingPathComponent("downloads")
        try makeProject(root.appendingPathComponent("1"), type: "application", marker: "old")
        let updater = StagedUpdater(root: root, checker: .init(assets: nil), deepCheck: false) { _, destination in
            try makeProject(destination, marker: "new")
        }
        let better = await updater.update(item(1))
        XCTAssertEqual(better, .installed(previousKept: true))
        XCTAssertEqual(try marker(root.appendingPathComponent("1")), "new")
        XCTAssertEqual(try marker(root.appendingPathComponent(".previous/1")), "old")
        try updater.rollback(1)
        XCTAssertEqual(try marker(root.appendingPathComponent("1")), "old")
        _ = await updater.update(item(1))
        let equal = await updater.update(item(1))
        XCTAssertEqual(equal, .installed(previousKept: true))
        XCTAssertEqual(try marker(root.appendingPathComponent(".previous/1")), "new")
    }

    func testHeldForceAndState() async throws {
        let root = temporary.appendingPathComponent("downloads")
        let stateURL = temporary.appendingPathComponent("custom/state.json")
        try makeProject(root.appendingPathComponent("1"), marker: "old")
        let original = SyncState(lastSync: Date(timeIntervalSince1970: 123), declined: [9])
        try original.save(to: stateURL)
        let updater = StagedUpdater(root: root, checker: .init(assets: nil), deepCheck: false, stateURL: stateURL) { _, destination in
            try makeProject(destination, type: "application", marker: "new")
        }
        let held = await updater.update(item(1, manifest: 11))
        XCTAssertEqual(held, .held(reason: .unsupported))
        XCTAssertEqual(try marker(root.appendingPathComponent("1")), "old")
        var state = try SyncState.load(from: stateURL)
        XCTAssertEqual(state.held[1], .init(itemID: 1, manifestID: 11, reason: .unsupported))
        XCTAssertEqual(state.lastSync, original.lastSync)
        XCTAssertEqual(state.declined, [9])
        state.dismiss(1)
        try state.save(to: stateURL)
        XCTAssertEqual(try SyncState.load(from: stateURL), original)
        _ = await updater.update(item(1, manifest: 11))
        let forced = await updater.update(item(1, manifest: 11), force: true)
        XCTAssertEqual(forced, .installed(previousKept: true))
        XCTAssertEqual(try marker(root.appendingPathComponent("1")), "new")
        XCTAssertTrue(try SyncState.load(from: stateURL).held.isEmpty)
    }

    func testFailureAndResume() async throws {
        let root = temporary.appendingPathComponent("downloads")
        try makeProject(root.appendingPathComponent("1"), marker: "old")
        let failing = StagedUpdater(root: root, checker: .init(assets: nil), deepCheck: false) { _, destination in
            try makeProject(destination, marker: "partial")
            throw CocoaError(.fileReadUnknown)
        }
        let failed = await failing.update(item(1))
        guard case .failed = failed else { return XCTFail("Expected failure") }
        XCTAssertEqual(try marker(root.appendingPathComponent("1")), "old")
        let resuming = StagedUpdater(root: root, checker: .init(assets: nil), deepCheck: false) { _, destination in
            guard try String(contentsOf: destination.appendingPathComponent("marker"), encoding: .utf8) == "partial" else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try makeProject(destination, marker: "resumed")
        }
        let resumed = await resuming.update(item(1))
        XCTAssertEqual(resumed, .installed(previousKept: true))
        XCTAssertEqual(try marker(root.appendingPathComponent("1")), "resumed")
    }

    func testMissingAssetsAndComparison() async throws {
        let root = temporary.appendingPathComponent("downloads")
        try makeProject(root.appendingPathComponent("1"), marker: "old")
        let updater = StagedUpdater(root: root, checker: .init(assets: nil), deepCheck: false) { _, destination in
            try makeProject(destination, type: "scene")
        }
        let held = await updater.update(item(1))
        XCTAssertEqual(held, .held(reason: .missingAssets))
        XCTAssertEqual(try marker(root.appendingPathComponent("1")), "old")
        XCTAssertEqual(StagedUpdater.regression(from: .init(status: .partial, missing: [.light: 1]),
                                               to: .init(status: .partial, missing: [.light: 1, .model3D: 1])), .lostFeatures([.model3D]))
        XCTAssertNil(StagedUpdater.regression(from: .init(status: .unsupported), to: .init(status: .needsAssets)))
        XCTAssertNil(StagedUpdater.regression(from: .init(status: .partial, missing: [.light: 1]), to: .init(status: .supported)))
        for reason: HoldReason in [.missingAssets, .lostFeatures([.light, .model3D])] {
            let state = SyncState(held: [1: .init(itemID: 1, manifestID: 10, reason: reason)])
            try state.save(to: updater.stateURL)
            XCTAssertEqual(try SyncState.load(from: updater.stateURL), state)
        }
    }

    func testFirstInstallAndInvalidItem() async throws {
        let root = temporary.appendingPathComponent("downloads")
        let updater = StagedUpdater(root: root, checker: .init(assets: nil), deepCheck: false) { _, destination in
            try makeProject(destination)
        }
        let installed = await updater.update(item(1))
        XCTAssertEqual(installed, .installed(previousKept: false))
        let rejected = await updater.update(item(2, result: 9))
        guard case .failed = rejected else { return XCTFail("Expected failed Steam item to be rejected") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("2").path))
        XCTAssertThrowsError(try updater.rollback(2))
        XCTAssertEqual(try SyncState.load(from: temporary.appendingPathComponent("absent.json")), SyncState())
    }

    func testStateWriteFailureRestoresCurrent() async throws {
        let root = temporary.appendingPathComponent("downloads")
        let stateURL = temporary.appendingPathComponent("state.json")
        try makeProject(root.appendingPathComponent("1"), marker: "old")
        let updater = StagedUpdater(root: root, checker: .init(assets: nil), deepCheck: false, stateURL: stateURL) { _, destination in
            try makeProject(destination, marker: "new")
            // Make the state destination unwritable after its successful initial read.
            try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
        }
        let outcome = await updater.update(item(1))
        guard case .failed = outcome else { return XCTFail("Expected state write failure") }
        XCTAssertEqual(try marker(root.appendingPathComponent("1")), "old")
        XCTAssertEqual(try marker(root.appendingPathComponent(".staging/1")), "new")
    }

    private func marker(_ folder: URL) throws -> String {
        try String(contentsOf: folder.appendingPathComponent("marker"), encoding: .utf8)
    }
}

private func item(_ id: UInt64, manifest: UInt64 = 10, time: TimeInterval = 100, result: Int = 1) -> WorkshopItem {
    WorkshopItem(id: id, appID: 431960, title: "Test", fileSize: 4,
                 timeUpdated: Date(timeIntervalSince1970: time), contentManifestID: manifest, result: result)
}

private func makeProject(_ folder: URL, type: String = "web", marker: String = "new") throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["title": "Test", "type": type, "file": "index.html"])
        .write(to: folder.appendingPathComponent("project.json"))
    try Data("<html></html>".utf8).write(to: folder.appendingPathComponent("index.html"))
    try Data(marker.utf8).write(to: folder.appendingPathComponent("marker"))
}
