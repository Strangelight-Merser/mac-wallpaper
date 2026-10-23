import Foundation
import XCTest

final class CLITests: LibraryTestCase {
    func testScanAndShow() throws {
        let folder = try project("root/app", type: "application", extra: ["workshopid": "123"])
        let root = folder.deletingLastPathComponent()
        let index = temporary.appendingPathComponent("index.json")
        let scan = try command(["scan", "--root", root.path, "--json", "--index", index.path])
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: scan) as? [String: Any])
        let entries = try XCTUnwrap(output["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1); XCTAssertEqual(entries[0]["id"] as? String, "ws:123")
        let summary = try XCTUnwrap(output["summary"] as? [String: Any])
        XCTAssertEqual(summary["missingFeatures"] as? [String: Int], ["applicationWallpaper": 1])
        XCTAssertTrue(FileManager.default.fileExists(atPath: index.path))
        let show = try command(["show", folder.path])
        let entry = try XCTUnwrap(JSONSerialization.jsonObject(with: show) as? [String: Any])
        XCTAssertEqual(entry["title"] as? String, "Fixture")
        XCTAssertEqual((entry["compatibility"] as? [String: Any])?["status"] as? String, "unsupported")
        let text = String(decoding: try command(["scan", "--root", root.path]), as: UTF8.self)
        XCTAssertTrue(text.contains("applicationWallpaper: 1 / 1"))
    }

    private func command(_ arguments: [String]) throws -> Data {
        let build = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let process = Process()
        process.executableURL = build.appendingPathComponent("wecli")
        process.arguments = ["library"] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
        return data
    }
}
