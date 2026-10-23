import Foundation
import XCTest
@testable import WELibrary

final class VideoTests: LibraryTestCase {
    func testWebMCodecInspectionAndMissingVideo() async throws {
        for codec in ["V_VP9", "V_AV1", "V_VP8", "V_UNKNOWN"] {
            let folder = try project(codec, type: "video", extra: ["file": "test.webm"])
            try write("\(codec)/test.webm", webm(codec))
            let result = await CompatibilityChecker(assets: nil).check(WallpaperEntry(folder: folder, root: .userFolder), deep: false)
            XCTAssertEqual(result.status, codec == "V_UNKNOWN" ? .unsupported : .supported)
            XCTAssertEqual(result.missing[.unsupportedVideoCodec], codec == "V_UNKNOWN" ? 1 : nil)
        }
        let missing = try project("missing", type: "video", extra: ["file": "test.mp4"])
        let result = await CompatibilityChecker(assets: nil).check(WallpaperEntry(folder: missing, root: .userFolder), deep: false)
        XCTAssertEqual(result.missing[.missingAsset], 1)
        try write("missing/test.mp4", "broken movie")
        let corrupt = await CompatibilityChecker(assets: nil).check(WallpaperEntry(folder: missing, root: .userFolder), deep: false)
        XCTAssertEqual(corrupt.status, .unsupported)
        XCTAssertFalse(corrupt.notes.isEmpty)
    }

    private func webm(_ codec: String) -> Data {
        func element(_ id: [UInt8], _ data: Data) -> Data { Data(id) + Data([0x80 | UInt8(data.count)]) + data }
        let track = element([0xD7], Data([1])) + element([0x83], Data([1])) + element([0x86], Data(codec.utf8))
        let tracks = element([0x16, 0x54, 0xAE, 0x6B], element([0xAE], track))
        return element([0x1A, 0x45, 0xDF, 0xA3], Data()) + element([0x18, 0x53, 0x80, 0x67], tracks)
    }
}
