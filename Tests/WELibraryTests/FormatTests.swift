import Foundation
import Metal
import XCTest
import WEFormat
import WEShader
import WERender
@testable import WELibrary

final class FormatTests: LibraryTestCase {
    func testVDF() throws {
        let value = try VDF.parse(#"""
        // libraries
        "libraryfolders" {
            "0" { "path" "/Library/Steam" "apps" { "431960" "12" } }
            "1" { "path" "C:\\Steam\"quoted\"\n\t" } // tail
        }
        "repeat" "a" "repeat" "b"
        """#)
        XCTAssertEqual(value["libraryfolders"]?["0"]?["apps"]?["431960"]?.string, "12")
        XCTAssertEqual(value["libraryfolders"]?["1"]?["path"]?.string, "C:\\Steam\"quoted\"\n\t")
        XCTAssertEqual(value.pairs.filter { $0.key == "repeat" }.count, 2)
        for invalid in ["\"a\" {", "\"a\"", "}", "\"unterminated", "a { b }"] {
            XCTAssertThrowsError(try VDF.parse(invalid))
        }
    }

    func testSteamLibraryFolders() throws {
        let steam = temporary.appendingPathComponent("Steam")
        let other = temporary.appendingPathComponent("Other")
        try write("Steam/steamapps/libraryfolders.vdf", "\"libraryfolders\" { \"0\" { \"path\" \"\(steam.path)\" } \"1\" { \"path\" \"\(other.path)\" } \"2\" { \"path\" \"/nonexistent-fixture\" } }")
        for url in [steam, other] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent("steamapps/workshop/content/431960"), withIntermediateDirectories: true)
        }
        XCTAssertEqual(LibraryRoots.steamWorkshopRoots(steam: steam).count, 2)
    }

    func testMappedPackageLookupAndBounds() throws {
        let files = [("Test.txt", Data("upper".utf8)), ("test.txt", Data("lower".utf8)), ("empty", Data())]
        let url = try write("scene.pkg", package(files))
        let pkg = try PKG(url: url)
        XCTAssertEqual(pkg.entries.count, 3)
        XCTAssertEqual(pkg.contents(path: "test.txt"), files[1].1)
        XCTAssertEqual(pkg.contents(path: "TEST.TXT"), files[0].1)
        XCTAssertEqual(pkg.contents(path: "empty"), Data())
        XCTAssertNil(pkg.contents(path: "missing"))
        XCTAssertEqual(try PKG(bytes: Array(package(files))).contents(of: pkg.entries[0]), Array(files[0].1))
        let header = sized("PKGV0018") + word(1) + sized("x")
        let invalid: [Data] = [Data(), sized("bad") + word(0), sized("PKGV0018") + word(-1),
                               header + word(-1) + word(1), header + word(0) + word(99)]
        for bytes in invalid {
            XCTAssertThrowsError(try PKG(bytes: Array(bytes)))
        }
        try write("truncated.pkg", Data(package(files).dropLast()))
        XCTAssertThrowsError(try PKG(url: temporary.appendingPathComponent("truncated.pkg")))
    }

    func testAssetPrecedenceAndExtraction() throws {
        let project = temporary.appendingPathComponent("project"), assets = temporary.appendingPathComponent("assets")
        let cache = temporary.appendingPathComponent("cache")
        try write("project/scene.pkg", package([("a", Data("pkg".utf8)), ("movie/test.mp4", Data("video".utf8)), ("project.json", Data("{}".utf8)), ("../escape", Data([1]))]))
        try write("project/a", "project"); try write("assets/a", "assets"); try write("assets/b", "assets")
        try write("assets/effects/ripple/shaders/effects/ripple_apply.vert", "effect")
        let locator = AssetLocator(project: project, assets: assets, cacheRoot: cache)
        XCTAssertEqual(try locator.string("a"), "project")
        try FileManager.default.removeItem(at: project.appendingPathComponent("a"))
        XCTAssertEqual(try locator.string("a"), "pkg")
        XCTAssertEqual(try locator.string("b"), "assets")
        XCTAssertEqual(try locator.string("shaders/effects/ripple_apply.vert"), "effect")
        XCTAssertTrue(locator.exists("MOVIE/test.mp4")); XCTAssertTrue(locator.exists("project.json"))
        XCTAssertFalse(locator.exists("../escape")); XCTAssertFalse(locator.exists("missing"))
        XCTAssertEqual(try locator.data("movie/test.mp4"), Data("video".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        let extracted = try XCTUnwrap(locator.url("movie/test.mp4"))
        XCTAssertTrue(extracted.path.hasPrefix(cache.path + "/"))
        XCTAssertEqual(try Data(contentsOf: extracted), Data("video".utf8))
        let timestamp = Date(timeIntervalSince1970: 123)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: extracted.path)
        XCTAssertEqual(locator.url("MOVIE/test.mp4"), extracted)
        XCTAssertEqual(try extracted.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, timestamp)
        XCTAssertEqual(extracted.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent.count, 16)
    }

    func testPackageIncludeMatchesDirectorySource() throws {
        let source = "#include \"common.h\"\n#include \"./common.h\"\nvoid main()\n{ gl_FragColor = fixture(); }\n"
        let header = "vec4 fixture() { return vec4(1.0); }\n"
        try write("packed/scene.pkg", package([("shaders/main.frag", Data(source.utf8)), ("shaders/common.h", Data(header.utf8))]))
        try write("loose/shaders/common.h", header)
        let packed = AssetLocator(project: temporary.appendingPathComponent("packed"), assets: nil, cacheRoot: temporary.appendingPathComponent("cache"))
        let loose = AssetLocator(project: temporary.appendingPathComponent("loose"), assets: nil)
        let a = try XCTUnwrap(ShaderPreprocessor.process(try packed.string("shaders/main.frag"), stage: .fragment, fileDirectory: "shaders", locator: packed, overrides: [:]))
        let b = try XCTUnwrap(ShaderPreprocessor.process(source, stage: .fragment, fileDirectory: "shaders", locator: loose, overrides: [:]))
        XCTAssertEqual(a.source, b.source)
        XCTAssertEqual(a.source.components(separatedBy: "vec4 fixture()").count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.appendingPathComponent("cache").path))
    }

    func testTextureVideoHeaderWithoutPayloadDecode() throws {
        for (data, expected) in [(texture(), false), (texture(videoFlag: true), true), (texture(mp4: true), true)] {
            XCTAssertEqual(try Tex.isVideo(data: data), expected)
            XCTAssertEqual(try Tex.isVideo(data: Data(data.dropLast(4))), expected)
        }
        XCTAssertThrowsError(try Tex.isVideo(data: Data()))
    }

    func testPackedSceneDescription() throws {
        let folder = try scene(packed: true)
        let locator = AssetLocator(project: folder, assets: nil, cacheRoot: temporary.appendingPathComponent("cache"))
        let description = try SceneDescription(project: folder, locator: locator)
        XCTAssertEqual(description.layers.count, 1)
        XCTAssertEqual(description.layers[0].passes[0].textures, ["test"])
        XCTAssertEqual(try Tex(data: locator.data("materials/test.tex")).images[0][0].bytes, [255, 0, 0, 255])
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.appendingPathComponent("cache").path))
    }

    func testWallpaperOpenPackedScene() throws {
        let folder = try scene(packed: true)
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device in sandbox; reviewer must verify PKG rendering and regression") }
        let renderer = try Wallpaper.open(project: folder, assets: nil)
        XCTAssertTrue(renderer is SceneRenderer)
        let frame = try renderer.render(width: 16, height: 16, time: 1)
        XCTAssertEqual(frame.width, 16)
        XCTAssertTrue(renderer.warnings.isEmpty, renderer.warnings.joined(separator: "\n"))
    }
}
