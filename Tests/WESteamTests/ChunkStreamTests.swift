import Foundation
import XCTest
@testable import WESteam

final class ChunkStreamTests: XCTestCase {
    func vsza(_ plain: Data) -> Data {
        var d = Data("VSZa".utf8); d.appendLE(UInt32(0))
        d.append(Data([0x28, 0xb5, 0x2f, 0xfd, 0xa0])); d.appendLE(UInt32(plain.count))
        var offset = 0
        repeat {
            let count = min(65536, plain.count - offset)
            let header = UInt32(count << 3 | (offset + count == plain.count ? 1 : 0))
            d.append(UInt8(truncatingIfNeeded: header)); d.append(UInt8(truncatingIfNeeded: header >> 8)); d.append(UInt8(truncatingIfNeeded: header >> 16))
            d.append(plain.subdata(in: offset..<offset + count)); offset += count
        } while offset < plain.count
        d.appendLE(ChunkCodec.crc32(plain)); d.appendLE(UInt32(plain.count)); d.appendLE(UInt32(0)); d.append(Data("zsv".utf8))
        return d
    }
    func testPrefixesAndFinish() throws {
        let plain = Data((0..<50000).map { UInt8(truncatingIfNeeded: $0 * 37) })
        for payload in [vsza(plain), try vzip(plain), try zip(plain, compressed: true), try zip(plain, compressed: true, descriptor: true), try zip(plain, compressed: false), try zip(plain, compressed: false, descriptor: true)] {
            let encrypted = try encrypt(payload)
            var seed: UInt64 = 42
            let randomSizes = (0..<100).map { _ -> Int in
                seed = seed &* 6364136223846793005 &+ 1
                return Int(seed % 4096) + 1
            }
            for sizes in [[1], [7], [16], [4096], randomSizes] {
                var decoder = ChunkStream(key: testKey), accumulated = Data(), offset = 0, step = 0
                while offset < encrypted.count {
                    let end = min(encrypted.count, offset + sizes[step % sizes.count])
                    accumulated.append(try decoder.append(encrypted.subdata(in: offset..<end)))
                    XCTAssertEqual(accumulated, decoder.plaintext)
                    XCTAssertEqual(accumulated, Data(plain.prefix(accumulated.count)))
                    offset = end; step += 1
                }
                accumulated.append(try decoder.finish())
                XCTAssertEqual(accumulated, plain)
            }
        }
    }
    func testCompressedZstdFrame() throws {
        let hex = "28b52ffd0468fd0000b857616c6c706170657220456e67696e65206368756e6b200100bd43fbd90462c79f5f"
        let frame = Data(stride(from: 0, to: hex.count, by: 2).map {
            UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)...].prefix(2), radix: 16)!
        })
        let plain = Data(String(repeating: "Wallpaper Engine chunk ", count: 200).utf8)
        var payload = Data("VSZa".utf8); payload.appendLE(UInt32(0)); payload.append(frame)
        payload.appendLE(ChunkCodec.crc32(plain)); payload.appendLE(UInt32(plain.count))
        payload.appendLE(UInt32(0)); payload.append(Data("zsv".utf8))
        var decoder = ChunkStream(key: testKey)
        for byte in try encrypt(payload) {
            _ = try decoder.append(Data([byte]))
            XCTAssertEqual(decoder.plaintext, Data(plain.prefix(decoder.plaintext.count)))
        }
        _ = try decoder.finish()
        XCTAssertEqual(decoder.plaintext, plain)
    }
    func testLimitsAndInvalidInput() throws {
        let plain = Data(repeating: 99, count: 10000)
        for payload in [vsza(plain), try vzip(plain), try zip(plain, compressed: true), try zip(plain, compressed: false), try zip(plain, compressed: false, descriptor: true)] {
            var decoder = ChunkStream(key: testKey, maxOutput: 99)
            XCTAssertThrowsError(try decoder.append(encrypt(payload)))
        }
        var unknown = ChunkStream(key: testKey)
        XCTAssertThrowsError(try unknown.append(encrypt(Data(repeating: 88, count: 50))))
        var truncated = ChunkStream(key: testKey)
        _ = try truncated.append(encrypt(vsza(plain)).prefix(4000))
        XCTAssertGreaterThan(truncated.plaintext.count, 0)
        XCTAssertLessThan(truncated.plaintext.count, plain.count)
        XCTAssertEqual(truncated.plaintext, Data(plain.prefix(truncated.plaintext.count)))
    }
}
