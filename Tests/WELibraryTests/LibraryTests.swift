import Foundation
import XCTest
@testable import WELibrary

final class LibraryTests: LibraryTestCase {
    func testDiscoveryDepthAndExcludedFolders() throws {
        for path in ["root", "root/one", "root/one/two", "root/one/two/three", "root/one/two/three/four", "root/.hidden", "root/staging.partial"] {
            _ = try project(path)
        }
        try FileManager.default.createSymbolicLink(at: temporary.appendingPathComponent("root/link"), withDestinationURL: temporary.appendingPathComponent("root/one"))
        let root = temporary.appendingPathComponent("root")
        XCTAssertEqual(LibraryRoots.discover([LibraryRoot(url: root, kind: .downloads)]).count, 2)
        XCTAssertEqual(LibraryRoots.discover([LibraryRoot(url: root, kind: .userFolder)]).count, 4)
        XCTAssertEqual(LibraryRoots.discover([LibraryRoot(url: root, kind: .userFolder), LibraryRoot(url: root, kind: .downloads)]).count, 4)
    }

    func testMetadataAndMalformedFields() throws {
        let folder = try project("valid", extra: ["workshopid": "18446744073709551615", "tags": ["Nature", "Relaxing"], "contentrating": "Mature", "preview": "preview.png", "general": ["properties": ["schemecolor": [:], "speed": ["value": 1]], "supportsaudioprocessing": true]])
        try write("valid/preview.png", Data([1, 2, 3]))
        let main = try write("valid/scene.json", "{}")
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: main.path)
        try write("outside", Data(repeating: 0, count: 1000))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: temporary.appendingPathComponent("outside"))
        let entry = WallpaperEntry(folder: folder, root: .steamWorkshop)
        XCTAssertEqual(entry.id, "ws:18446744073709551615"); XCTAssertEqual(entry.workshopID, UInt64.max)
        XCTAssertEqual(entry.contentRating, .mature); XCTAssertEqual(entry.tags, ["Nature", "Relaxing"])
        XCTAssertTrue(entry.hasUserProperties); XCTAssertTrue(entry.audioResponsive); XCTAssertNotNil(entry.preview)
        XCTAssertEqual(entry.modified, date); XCTAssertTrue(entry.problems.isEmpty)
        let projectSize = try Data(contentsOf: folder.appendingPathComponent("project.json")).count
        XCTAssertEqual(entry.sizeOnDisk, Int64(projectSize + 5))
        try json("bad/project.json", ["title": 5, "file": [], "type": "invalid", "workshopid": "abc", "tags": ["ok", 1], "contentrating": "wrong", "general": "bad"])
        let bad = WallpaperEntry(folder: temporary.appendingPathComponent("bad"), root: .userFolder)
        XCTAssertTrue(bad.id.hasPrefix("dir:")); XCTAssertEqual(bad.title, "bad"); XCTAssertEqual(bad.type, .unknown)
        XCTAssertGreaterThanOrEqual(bad.problems.count, 7); XCTAssertEqual(bad.tags, ["ok"])
        try write("broken/project.json", "{")
        XCTAssertFalse(WallpaperEntry(folder: temporary.appendingPathComponent("broken"), root: .downloads).problems.isEmpty)
        try json("inferred/project.json", ["title": "inferred", "file": "scene.json", "general": ["properties": ["schemecolor": [:]]]])
        let inferred = WallpaperEntry(folder: temporary.appendingPathComponent("inferred"), root: .userFolder)
        XCTAssertEqual(inferred.type, .scene); XCTAssertEqual(inferred.contentRating, .everyone); XCTAssertFalse(inferred.hasUserProperties)
    }

    func testStaticCompatibility() async throws {
        let assets = temporary.appendingPathComponent("assets")
        let folder = try scene(packed: true)
        let entry = WallpaperEntry(folder: folder, root: .userFolder)
        let checker = CompatibilityChecker(assets: assets)
        let supported = await checker.check(entry, deep: false)
        XCTAssertEqual(supported.status, .supported); XCTAssertTrue(supported.missing.isEmpty)
        let noAssets = await CompatibilityChecker(assets: nil).check(entry, deep: false)
        XCTAssertEqual(noAssets.status, .needsAssets)
        let partialFolder = try scene("partial", objects: [
            ["name": "image", "image": "models/test.json", "effects": [["file": "effects/missing.json"]], "alpha": ["script": "x", "nested": ["scriptproperties": [:]]]],
            ["particle": "p"], ["text": "hello"], ["model": "3d"], ["sound": "s"], ["light": [:]], ["strange": true]])
        let partial = await checker.check(WallpaperEntry(folder: partialFolder, root: .userFolder), deep: false)
        XCTAssertEqual(partial.status, .partial)
        for feature: Feature in [.particles, .text, .model3D, .sound, .light, .sceneScript, .missingEffect, .unknownObject] {
            XCTAssertEqual(partial.missing[feature], 1, feature.rawValue)
        }
        let app = try project("app", type: "application")
        let application = await checker.check(WallpaperEntry(folder: app, root: .downloads), deep: false)
        XCTAssertEqual(application.status, .unsupported); XCTAssertEqual(application.missing, [.applicationWallpaper: 1])
        let web = try project("web", type: "web")
        let missing = await checker.check(WallpaperEntry(folder: web, root: .userFolder), deep: false)
        XCTAssertEqual(missing.status, .unsupported); XCTAssertEqual(missing.missing[.missingAsset], 1)
        try write("web/main.html", "<html></html>")
        let page = await checker.check(WallpaperEntry(folder: web, root: .userFolder), deep: true)
        XCTAssertEqual(page.status, .supported); XCTAssertFalse(page.checkedDeep)
    }

    func testPuppetVideoTexturesAndMissingAssets() async throws {
        let folder = try scene()
        let checker = CompatibilityChecker(assets: temporary)
        try json("project/models/test.json", ["material": "materials/test.json", "puppet": [:]])
        try write("project/materials/test.tex", texture(videoFlag: true))
        var result = await checker.check(WallpaperEntry(folder: folder, root: .userFolder), deep: false)
        XCTAssertEqual(result.status, .unsupported); XCTAssertEqual(result.missing[.puppetWarp], 1); XCTAssertEqual(result.missing[.videoTexture], 1)
        try write("project/materials/test.tex", texture(mp4: true))
        result = await checker.check(WallpaperEntry(folder: folder, root: .userFolder), deep: false)
        XCTAssertEqual(result.missing[.videoTexture], 1)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("materials/test.tex"))
        result = await checker.check(WallpaperEntry(folder: folder, root: .userFolder), deep: false)
        XCTAssertEqual(result.missing[.missingAsset], 1)
    }
}
