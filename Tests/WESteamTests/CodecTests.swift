import CSteamSupport
import Foundation
import XCTest
@testable import WESteam

final class CodecTests: XCTestCase {
    func testProtobufEdgesAndUnknownFields() throws {
        for value: UInt64 in [0, 1, 127, 128, 16383, 16384, UInt64(UInt32.max), UInt64.max] {
            var p = ProtoWriter(); p.uint(1, value); p.fixed64(2, value)
            var nested = ProtoWriter(); nested.string(1, "nested"); p.bytes(3, nested.data)
            p.fixed32(99, 0xaabbccdd); p.uint(100, 42); p.bytes(101, Data([1, 2]))
            let r = try ProtoReader(p.data)
            XCTAssertEqual(r.uint(1), value); XCTAssertEqual(r.uint(2), value)
            XCTAssertEqual(try ProtoReader(r.bytes(3)).string(1), "nested")
            XCTAssertEqual(r.uint(99), 0xaabbccdd)
        }
        for bytes: [UInt8] in [[0], [8, 128], [10, 5, 1], [9, 1], [8] + Array(repeating: 255, count: 10)] {
            XCTAssertThrowsError(try ProtoReader(Data(bytes)))
        }
    }
    func testMessageFieldsAndFraming() throws {
        var header = CMHeader(); header.steamID = testSteamID; header.sessionID = -12345
        header.sourceJob = 99; header.targetJob = 123; header.method = "Test.Call#1"
        header.result = 1; header.realm = 1; header.errorMessage = "fixture"
        XCTAssertEqual(try CMHeader(header.encoded()), header)
        let logon = CMLogon(tokens: try testTokens(), machineName: "test")
        XCTAssertTrue(try CMLogon(logon.encoded()) == logon)
        let fields = try ProtoReader(logon.encoded())
        XCTAssertEqual(fields.uint(1), 65580); XCTAssertFalse(fields.contains(50))
        XCTAssertEqual(fields.uint(7), UInt64(UInt32(bitPattern: -102)))
        let packet = CMPacket(.logOn, header: header, body: logon.encoded())
        let decoded = try CMPacket(packet.encoded())
        XCTAssertEqual(decoded.message, 5514); XCTAssertEqual(decoded.header, header)
        XCTAssertTrue(decoded.body == packet.body)
        XCTAssertThrowsError(try CMPacket(Data([1, 0, 0, 128, 255, 255, 255, 255])))
        var p = ProtoWriter(); p.uint(1, 1); p.uint(3, 30); p.uint(7, 42)
        p.fixed64(20, testSteamID); p.string(21, "US"); p.uint(90, 1)
        let r = try CMLogonResponse(p.data)
        XCTAssertEqual(r.result, 1); XCTAssertEqual(r.heartbeat, 30); XCTAssertEqual(r.cellID, 42)
        XCTAssertEqual(r.country, "US"); XCTAssertEqual(r.suppliedSteamID, testSteamID)
    }
    func testMultiCompressedAndPlain() throws {
        let packets = [CMPacket(.heartbeat), CMPacket(.serviceResponse, body: Data([1, 2, 3]))]
        var body = Data()
        for packet in packets {
            let data = packet.encoded(); body.appendLE(UInt32(data.count)); body.append(data)
        }
        for compressed in [false, true] {
            var p = ProtoWriter(); p.uint(1, compressed ? UInt64(body.count) : 0)
            p.bytes(2, compressed ? try deflate(body, window: 31) : body)
            let children = try CMPacket(.multi, body: p.data).children()
            XCTAssertEqual(children.map(\.message), packets.map(\.message))
            XCTAssertEqual(children.map(\.body), packets.map(\.body))
        }
        var malformed = ProtoWriter(); malformed.bytes(2, Data([255, 255, 255, 255]))
        XCTAssertThrowsError(try CMPacket(.multi, body: malformed.data).children())
    }
    func testAESAllPaddingLengthsAndCorruption() throws {
        for padding in 1...16 {
            let plain = Data(repeating: UInt8(padding), count: 32 - padding)
            XCTAssertEqual(try ChunkCodec.decrypt(encrypt(plain), key: testKey), plain)
        }
        let footer = Data(repeating: 1, count: 23) + Data("zv".utf8)
        XCTAssertEqual(try ChunkCodec.decrypt(encrypt(footer), key: testKey), footer)
        for bad in [Data(repeating: 0, count: 16), Data(repeating: 17, count: 16),
                    Data(repeating: 9, count: 15) + Data([2])] {
            XCTAssertThrowsError(try ChunkCodec.decrypt(encrypt(bad, padding: false), key: testKey))
        }
        XCTAssertThrowsError(try ChunkCodec.decrypt(Data(repeating: 0, count: 17), key: testKey))
    }
    func testLZMAABIRoundTripAndVZipChecks() throws {
        XCTAssertEqual(MemoryLayout<lzma_stream>.size, 136)
        XCTAssertEqual(MemoryLayout<lzma_options_lzma>.size, 112)
        for plain in [Data(), Data("hello LZMA".utf8), Data((0..<50000).map { UInt8($0 % 251) })] {
            let packed = try vzip(plain)
            XCTAssertEqual(try ChunkCodec.decompress(packed), plain)
            var badCRC = packed; badCRC[badCRC.count - 10] ^= 1
            XCTAssertThrowsError(try ChunkCodec.decompress(badCRC))
            var badSize = packed; badSize[badSize.count - 6] ^= 1
            XCTAssertThrowsError(try ChunkCodec.decompress(badSize))
            var badFooter = packed; badFooter[badFooter.count - 1] = 0
            XCTAssertThrowsError(try ChunkCodec.decompress(badFooter))
        }
    }
    func testZIPStoredDeflatedAndDescriptor() throws {
        let plain = Data(repeating: 123, count: 20000)
        for compressed in [false, true] {
            for descriptor in [false, true] {
                let packed = try zip(plain, compressed: compressed, descriptor: descriptor)
                XCTAssertEqual(try ChunkCodec.decompress(packed), plain)
                XCTAssertThrowsError(try ChunkCodec.decompress(packed, maxOutput: plain.count - 1))
                var bad = packed; bad[bad.count - 22 - 47 + 16] ^= 1
                XCTAssertThrowsError(try ChunkCodec.decompress(bad))
            }
        }
        XCTAssertThrowsError(try ChunkCodec.decompress(Data("VSZa".utf8))) {
            XCTAssertEqual($0 as? SteamError, .unsupportedCompression("zstd"))
        }
    }
    func testManifestEncryptedPathsAndPlanner() throws {
        let plain = Data("wallpaper".utf8)
        let (bytes, responses) = try manifestData([FileFixture(path: "folder\\file.txt", data: plain)], encrypted: true)
        let manifest = try ContentManifest(data: bytes, key: testKey)
        XCTAssertEqual(manifest.files.first?.path, "folder/file.txt")
        XCTAssertEqual(manifest.depotID, 431960); XCTAssertEqual(manifest.manifestID, 99)
        let plan = try DownloadPlan(item: item(), manifest: manifest, key: testKey, servers: [])
        XCTAssertEqual(plan.diskBytes, Int64(plain.count))
        XCTAssertEqual(plan.networkBytes, Int64(responses.values.reduce(0) { $0 + $1.count }))
        XCTAssertNoThrow(try plan.checkLimit(plan.networkBytes))
        XCTAssertThrowsError(try plan.checkLimit(plan.networkBytes - 1)) { XCTAssertEqual($0 as? SteamError, .tooLarge(plan.networkBytes)) }
        XCTAssertThrowsError(try ContentManifest(data: Data(bytes.dropLast()), key: testKey))
        for path in ["/absolute", "../escape", "a/../escape", "C:\\escape", "\\\\server\\share", "a\0b", ".steam-manifest.json"] {
            let bad = try manifestData([FileFixture(path: path, data: plain)]).0
            XCTAssertThrowsError(try ContentManifest(data: bad, key: testKey))
        }
        let conflict = try manifestData([FileFixture(path: "a", data: plain), FileFixture(path: "a/b", data: plain)]).0
        XCTAssertThrowsError(try ContentManifest(data: conflict, key: testKey))
    }
    func testChunkIntegrity() throws {
        let plain = Data("payload".utf8), packed = try encrypt(vzip(plain))
        XCTAssertEqual(try ChunkCodec.decode(packed, key: testKey, sha: ChunkCodec.sha1(plain),
                                             originalSize: plain.count, compressedSize: packed.count), plain)
        XCTAssertThrowsError(try ChunkCodec.decode(packed, key: testKey, sha: Data(repeating: 0, count: 20),
                                                  originalSize: plain.count, compressedSize: packed.count))
        XCTAssertThrowsError(try ChunkCodec.decode(packed, key: testKey, sha: ChunkCodec.sha1(plain),
                                                  originalSize: plain.count + 1, compressedSize: packed.count))
    }
}
