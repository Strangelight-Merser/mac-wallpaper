import CSteamSupport
import CryptoKit
import Foundation

/// Steam depot encryption and VZip/ZIP decompression with integrity checks.
public enum ChunkCodec {
    public static func sha1(_ data: Data) -> Data { Data(Insecure.SHA1.hash(data: data)) }
    public static func crc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { UInt32(CSteamSupport.crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(data.count))) }
    }
    public static func decrypt(_ data: Data, key: Data) throws -> Data {
        guard key.count == 32, data.count >= 32, data.count % 16 == 0 else {
            throw SteamError.malformed("AES block length")
        }
        // @doctormckay/steam-crypto/index.js; manual PKCS#7 per spec §7.3.
        let iv = try crypt(Data(data.prefix(16)), key: key, iv: Data(repeating: 0, count: 16), ecb: true)
        let plain = try crypt(Data(data.dropFirst(16)), key: key, iv: iv, ecb: false)
        guard let last = plain.last, (1...16).contains(last),
              plain.suffix(Int(last)).allSatisfy({ $0 == last }) else {
            throw SteamError.malformed("AES padding")
        }
        return Data(plain.dropLast(Int(last)))
    }
    static func crypt(_ data: Data, key: Data, iv: Data, ecb: Bool) throws -> Data {
        var out = Data(count: data.count + 16), written = 0
        let capacity = out.count
        let status = out.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                ecb ? CCOptions(kCCOptionECBMode) : 0, keyBytes.baseAddress, key.count,
                                ivBytes.baseAddress, input.baseAddress, data.count, output.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw SteamError.malformed("AES decryption") }
        out.count = written
        return out
    }
    public static func decompress(_ data: Data, maxOutput: Int = 64 * 1024 * 1024) throws -> Data {
        // steam-user/components/cdn_compression.js: headers, properties offset and footers.
        if data.starts(with: Data("VSZa".utf8)) { throw SteamError.unsupportedCompression("zstd") }
        if data.starts(with: Data("VZa".utf8)) {
            guard data.count >= 22, data.suffix(2) == Data("zv".utf8) else { throw SteamError.malformed("VZip footer") }
            let crc = try data.uint32(at: data.count - 10), size = Int(try data.uint32(at: data.count - 6))
            guard size <= maxOutput else { throw SteamError.malformed("VZip size limit") }
            var alone = data.subdata(in: 7..<12)
            alone.appendLE(UInt64(size))
            alone.append(data.subdata(in: 12..<data.count - 10))
            let result = try lzma(alone, size: size)
            guard crc32(result) == crc else { throw SteamError.malformed("VZip CRC") }
            return result
        }
        if data.starts(with: Data([0x50, 0x4b, 3, 4])) { return try unzip(data, maxOutput: maxOutput) }
        throw SteamError.unsupportedCompression("unknown")
    }
    public static func decode(_ data: Data, key: Data, sha: Data, originalSize: Int, compressedSize: Int) throws -> Data {
        guard data.count == compressedSize else { throw SteamError.malformed("chunk compressed size") }
        let result = try decompress(decrypt(data, key: key), maxOutput: originalSize)
        guard result.count == originalSize, sha1(result) == sha else { throw SteamError.malformed("chunk SHA-1 or size") }
        return result
    }
    static func lzma(_ data: Data, size: Int) throws -> Data {
        var stream = lzma_stream()
        guard lzma_alone_decoder(&stream, 256 * 1024 * 1024) == LZMA_OK else { throw SteamError.malformed("LZMA init") }
        defer { lzma_end(&stream) }
        var out = Data(count: size + 1)
        let status = data.withUnsafeBytes { input in
            out.withUnsafeMutableBytes { output in
                stream.next_in = input.bindMemory(to: UInt8.self).baseAddress; stream.avail_in = data.count
                stream.next_out = output.bindMemory(to: UInt8.self).baseAddress; stream.avail_out = size + 1
                return lzma_code(&stream, LZMA_FINISH)
            }
        }
        guard status == LZMA_STREAM_END, stream.total_out == size, stream.avail_in == 0 else {
            throw SteamError.malformed("LZMA data or size")
        }
        out.count = size
        return out
    }
    static func inflate(_ data: Data, size: Int, windowBits: Int32) throws -> Data {
        guard size >= 0, size < Int(UInt32.max), data.count <= Int(UInt32.max) else {
            throw SteamError.malformed("inflate size")
        }
        var stream = z_stream()
        guard inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw SteamError.malformed("inflate init")
        }
        defer { inflateEnd(&stream) }
        var out = Data(count: size + 1)
        let status = data.withUnsafeBytes { input in
            out.withUnsafeMutableBytes { output in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(data.count)
                stream.next_out = output.bindMemory(to: Bytef.self).baseAddress; stream.avail_out = uInt(size + 1)
                return CSteamSupport.inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, stream.total_out == size, stream.avail_in == 0 else {
            throw SteamError.malformed("deflate data or size")
        }
        out.count = size
        return out
    }
    static func unzip(_ data: Data, maxOutput: Int) throws -> Data {
        // ZIP APPNOTE local/central-directory layout; the reference uses adm-zip/util/constants.js.
        // Read sizes from the central directory, including archives using data descriptors.
        guard data.count >= 22 else { throw SteamError.malformed("ZIP header") }
        var end: Int?
        for i in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if try data.uint32(at: i) == 0x06054b50 {
                var tail = ByteCursor(data.subdata(in: i + 20..<data.count))
                if i + 22 + Int(try tail.integer(UInt16.self)) == data.count { end = i; break }
            }
        }
        guard let end else { throw SteamError.malformed("ZIP directory missing") }
        var e = ByteCursor(data.subdata(in: end + 4..<data.count))
        let disk = try e.integer(UInt16.self), startDisk = try e.integer(UInt16.self)
        let onDisk = try e.integer(UInt16.self), entries = try e.integer(UInt16.self)
        let directorySize = Int(try e.integer(UInt32.self)), directory = Int(try e.integer(UInt32.self))
        guard disk == 0, startDisk == 0, onDisk == 1, entries == 1,
              directory <= end, directorySize == end - directory else { throw SteamError.malformed("ZIP requires one entry") }
        var c = ByteCursor(data.subdata(in: directory..<end))
        guard try c.integer(UInt32.self) == 0x02014b50 else { throw SteamError.malformed("ZIP directory") }
        _ = try c.read(4)
        let flags = try c.integer(UInt16.self), method = try c.integer(UInt16.self)
        _ = try c.read(4)
        let crc = try c.integer(UInt32.self), compressed = Int(try c.integer(UInt32.self)), size = Int(try c.integer(UInt32.self))
        _ = try c.read(14)
        let localOffset = Int(try c.integer(UInt32.self))
        guard flags & 1 == 0, size <= maxOutput, localOffset < directory else { throw SteamError.malformed("ZIP flags or size") }
        var local = ByteCursor(data.subdata(in: localOffset..<directory))
        guard try local.integer(UInt32.self) == 0x04034b50 else { throw SteamError.malformed("ZIP local header") }
        _ = try local.read(2)
        guard try local.integer(UInt16.self) == flags, try local.integer(UInt16.self) == method else {
            throw SteamError.malformed("ZIP inconsistent header")
        }
        _ = try local.read(16)
        let nameLength = Int(try local.integer(UInt16.self)), extraLength = Int(try local.integer(UInt16.self))
        _ = try local.read(nameLength + extraLength)
        let payload = try local.read(compressed)
        let result: Data
        switch method {
        case 0: result = payload
        case 8: result = try inflate(payload, size: size, windowBits: -15)
        default: throw SteamError.unsupportedCompression("zip method \(method)")
        }
        guard result.count == size, crc32(result) == crc else { throw SteamError.malformed("ZIP CRC or size") }
        return result
    }
}
