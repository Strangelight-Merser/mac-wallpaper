import Foundation
import XCTest
@testable import WELibrary

private actor CheckedFolders {
    var folders: [URL] = []
    func add(_ url: URL) { folders.append(url) }
}

final class PresetTests: LibraryTestCase {
    private func preset(_ folder: String, base: Any = "111", values: [String: Any] = [:]) throws -> URL {
        try json("\(folder)/project.json", ["title": "Preset", "dependency": base, "preset": values, "tags": ["Anime"]])
        return temporary.appendingPathComponent(folder)
    }

    func testPresetEntry() throws {
        let entry = WallpaperEntry(folder: try preset("downloads/222"), root: .downloads)
        XCTAssertEqual(entry.preset, WallpaperEntry.Preset(base: 111))
        XCTAssertEqual(entry.workshopID, 222)  // from the folder name
        XCTAssertEqual(entry.id, "ws:222")
        XCTAssertEqual(entry.problems, [])     // no "missing file"/"unknown type" before resolving
        let numeric = WallpaperEntry(folder: try preset("other/x", base: 333), root: .userFolder)
        XCTAssertEqual(numeric.preset?.base, 333)
        XCTAssertNil(numeric.workshopID)
        // A project with its own file is not a preset, whatever "dependency" says.
        let plain = WallpaperEntry(folder: try project("plain", extra: ["dependency": "111"]), root: .userFolder)
        XCTAssertNil(plain.preset)
    }

    func testLibraryResolvesBase() async throws {
        let base = try project("downloads/111", extra: ["workshopid": "111", "general": ["supportsaudioprocessing": true]])
        _ = try preset("downloads/222")
        _ = try preset("downloads/444", base: "999")
        let checked = CheckedFolders()
        let library = WallpaperLibrary(indexURL: temporary.appendingPathComponent("index.json")) { entry, _, _ in
            await checked.add(entry.folder)
            return Compatibility(status: .supported)
        }
        let root = LibraryRoot(url: temporary.appendingPathComponent("downloads"), kind: .downloads)
        _ = await library.refresh(roots: [root], assets: nil, deep: false)
        let entries = await library.entries()
        let resolved = try XCTUnwrap(entries.first { $0.workshopID == 222 })
        XCTAssertEqual(resolved.preset?.baseFolder, base.standardizedFileURL)
        XCTAssertEqual(resolved.type, .scene)
        XCTAssertEqual(resolved.file, "scene.json")
        XCTAssertTrue(resolved.audioResponsive)
        XCTAssertEqual(resolved.compatibility?.status, .supported)
        let orphan = try XCTUnwrap(entries.first { $0.workshopID == 444 })
        XCTAssertNil(orphan.preset?.baseFolder)
        XCTAssertEqual(orphan.type, .unknown)
        XCTAssertEqual(orphan.compatibility?.missing, [.missingBase: 1])
        // The preset is checked with its base's content; the orphan isn't checked at all.
        let folders = await checked.folders
        XCTAssertEqual(folders.filter { $0 == base.standardizedFileURL }.count, 2)
        XCTAssertFalse(folders.contains { $0.lastPathComponent == "444" })
    }

    func testBaseChangeRechecksPreset() async throws {
        let base = try project("downloads/111", extra: ["workshopid": "111"])
        _ = try preset("downloads/222")
        let checked = CheckedFolders()
        let library = WallpaperLibrary(indexURL: temporary.appendingPathComponent("index.json")) { entry, _, _ in
            await checked.add(entry.folder)
            return Compatibility(status: .supported)
        }
        let root = LibraryRoot(url: temporary.appendingPathComponent("downloads"), kind: .downloads)
        _ = await library.refresh(roots: [root], assets: nil, deep: false)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)],
                                              ofItemAtPath: base.appendingPathComponent("project.json").path)
        let diff = await library.refresh(roots: [root], assets: nil, deep: false)
        XCTAssertEqual(diff.updated.sorted(), ["ws:111", "ws:222"])
        let count = await checked.folders.count
        XCTAssertEqual(count, 4)
    }

    func testPresetValues() throws {
        let folder = try preset("downloads/222", values: [
            "customimage": "files/a.png", "missing": "files/none.png", "escape": "../../etc/hosts",
            "colour": "0.5 0.25 1", "enabled": true, "count": 3, "absolute": "/tmp/x.png", "empty": "",
        ])
        try write("downloads/222/files/a.png", Data([0]))
        let values = WallpaperProperties.presetValues(folder: folder)
        XCTAssertEqual(values["customimage"], folder.appendingPathComponent("files/a.png").standardizedFileURL.path)
        XCTAssertEqual(values["missing"], "files/none.png")
        XCTAssertEqual(values["escape"], "../../etc/hosts")
        XCTAssertEqual(values["colour"], "0.5 0.25 1")
        XCTAssertEqual(values["enabled"], "true")
        XCTAssertEqual(values["count"], "3")
        XCTAssertEqual(values["absolute"], "/tmp/x.png")
        XCTAssertEqual(values["empty"], "")
        XCTAssertEqual(WallpaperProperties.presetValues(folder: temporary.appendingPathComponent("nothing")), [:])
    }

    func testSceneTextureKind() {
        let parsed = WallpaperProperties.parse(project: ["general": ["properties": [
            "picture": ["type": "scenetexture", "value": "", "text": "Picture"],
        ]]])
        XCTAssertEqual(parsed.first?.kind, .sceneTexture)
        XCTAssertEqual(parsed.first?.withDefault("/a.png").defaultValue, "/a.png")
        XCTAssertEqual(parsed.first?.withDefault("/a.png").label, "Picture")
    }
}
