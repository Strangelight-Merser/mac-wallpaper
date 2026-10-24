import Foundation
import CSteamSupport
import CZstd

public struct ChunkStream: ~Copyable {
    private let state: Decoder
    public var plaintext: Data { state.plaintext }
    public init(key: Data, maxOutput: Int = 4 * 1024 * 1024) {
        state = Decoder(key: key, maxOutput: maxOutput)
    }
    public mutating func append(_ encrypted: Data) throws -> Data { try state.append(encrypted, end: false) }
    public mutating func finish() throws -> Data { try state.append(Data(), end: true) }
}

private final class Decoder {
    let key: Data
    let maxOutput: Int
    var plaintext = Data(), encrypted = Data(), pending = Data()
    var iv: Data?
    var mode = 0, done = false, finished = false
    var storedRemaining: Int? = 0
    var zstd: UnsafeMutableRawPointer?
    var lzma = lzma_stream()
    var zip = z_stream()
    init(key: Data, maxOutput: Int) { self.key = key; self.maxOutput = maxOutput }
    deinit {
        if let zstd { czstd_stream_free(zstd) }
        if mode == 2 { lzma_end(&lzma) }
        if mode == 3 { inflateEnd(&zip) }
    }
    func append(_ data: Data, end: Bool) throws -> Data {
        guard !finished, key.count == 32, maxOutput >= 0 else { throw SteamError.malformed("chunk stream state") }
        let start = plaintext.count
        encrypted.append(data)
        if iv == nil, encrypted.count >= 16 {
            iv = try ChunkCodec.crypt(Data(encrypted.prefix(16)), key: key, iv: Data(repeating: 0, count: 16), ecb: true)
            encrypted = Data(encrypted.dropFirst(16))
        }
        if let iv {
            let count = end ? encrypted.count : max(0, (encrypted.count - 16) / 16 * 16)
            if end && (count == 0 || count % 16 != 0) { throw SteamError.malformed("AES block length") }
            if count > 0 {
                let blocks = Data(encrypted.prefix(count))
                var decoded = try ChunkCodec.crypt(blocks, key: key, iv: iv, ecb: false)
                self.iv = Data(blocks.suffix(16))
                encrypted = Data(encrypted.dropFirst(count))
                if end {
                    guard let pad = decoded.last, (1...16).contains(pad), decoded.suffix(Int(pad)).allSatisfy({ $0 == pad }) else {
                        throw SteamError.malformed("AES padding")
                    }
                    decoded.removeLast(Int(pad))
                }
                if !done { pending.append(decoded); try decompress() }
            }
        } else if end { throw SteamError.malformed("AES IV") }
        finished = end
        return Data(plaintext.dropFirst(start))
    }
    func decompress() throws {
        if mode == 0 {
            guard pending.count >= 4 else { return }
            if pending.starts(with: Data("VSZa".utf8)) {
                guard pending.count >= 8 else { return }
                zstd = czstd_stream_create()
                guard zstd != nil else { throw SteamError.malformed("zstd init") }
                mode = 1; pending = Data(pending.dropFirst(8))
            } else if pending.starts(with: Data("VZa".utf8)) {
                guard pending.count >= 12 else { return }
                guard lzma_alone_decoder(&lzma, 256 * 1024 * 1024) == LZMA_OK else { throw SteamError.malformed("LZMA init") }
                mode = 2
                pending = pending.subdata(in: 7..<12) + Data(repeating: 255, count: 8) + pending.dropFirst(12)
            } else if pending.starts(with: Data([80, 75, 3, 4])) {
                guard pending.count >= 30 else { return }
                func u16(_ i: Int) -> Int { Int(pending[i]) | Int(pending[i + 1]) << 8 }
                let flags = u16(6), method = u16(8), header = 30 + u16(26) + u16(28)
                guard flags & 1 == 0 else { throw SteamError.unsupportedCompression("encrypted ZIP") }
                guard pending.count >= header else { return }
                if method == 0 {
                    storedRemaining = flags & 8 == 0 ? Int(try pending.uint32(at: 18)) : nil; mode = 4
                } else if method == 8 {
                    guard inflateInit2_(&zip, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw SteamError.malformed("inflate init") }
                    mode = 3
                } else { throw SteamError.unsupportedCompression("zip method \(method)") }
                pending = Data(pending.dropFirst(header))
            } else { throw SteamError.unsupportedCompression("unknown") }
        }
        if mode == 4 {
            var count: Int
            if let remaining = storedRemaining {
                count = min(pending.count, remaining)
                storedRemaining = remaining - count
                done = storedRemaining == 0
            } else {
                count = max(0, pending.count - 24)
                if pending.count >= 12 {
                    for offset in 0...(pending.count - 12) {
                        let size = plaintext.count + offset
                        if try pending.uint32(at: offset + 4) == size,
                           try pending.uint32(at: offset + 8) == size,
                           try pending.uint32(at: offset) == ChunkCodec.crc32(plaintext + pending.prefix(offset)) {
                            count = offset; done = true; break
                        }
                        if offset >= 4, try pending.uint32(at: offset - 4) == 0x08074b50 {
                            let signed = plaintext + pending.prefix(offset - 4)
                            if try pending.uint32(at: offset + 4) == signed.count,
                               try pending.uint32(at: offset + 8) == signed.count,
                               try pending.uint32(at: offset) == ChunkCodec.crc32(signed) {
                                count = offset - 4; done = true; break
                            }
                        }
                    }
                }
            }
            guard count <= maxOutput - plaintext.count else { throw SteamError.malformed("chunk output limit") }
            plaintext.append(pending.prefix(count)); pending = Data(pending.dropFirst(count))
            if done { pending.removeAll() }
            return
        }
        while !done {
            var output = Data(count: min(16383, maxOutput - plaintext.count) + 1)
            let capacity = output.count
            var consumed = pending.count, written = capacity
            let status: Int32 = pending.withUnsafeBytes { input in
                output.withUnsafeMutableBytes { out in
                    if mode == 1 { return Int32(czstd_stream_update(zstd, input.baseAddress, &consumed, out.baseAddress, &written)) }
                    if mode == 2 {
                        lzma.next_in = input.bindMemory(to: UInt8.self).baseAddress; lzma.avail_in = pending.count
                        lzma.next_out = out.bindMemory(to: UInt8.self).baseAddress; lzma.avail_out = capacity
                        let result = lzma_code(&lzma, LZMA_RUN)
                        consumed -= lzma.avail_in; written -= lzma.avail_out
                        return result == LZMA_STREAM_END ? 1 : result == LZMA_OK ? 0 : -1
                    }
                    zip.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress); zip.avail_in = uInt(pending.count)
                    zip.next_out = out.bindMemory(to: UInt8.self).baseAddress; zip.avail_out = uInt(capacity)
                    let result = CSteamSupport.inflate(&zip, Z_NO_FLUSH)
                    consumed -= Int(zip.avail_in); written -= Int(zip.avail_out)
                    return result == Z_STREAM_END ? 1 : (result == Z_OK || result == Z_BUF_ERROR) ? 0 : -1
                }
            }
            guard status >= 0 else { throw SteamError.malformed("chunk decompression") }
            guard written <= maxOutput - plaintext.count else { throw SteamError.malformed("chunk output limit") }
            plaintext.append(output.prefix(written)); pending = Data(pending.dropFirst(consumed))
            done = status == 1
            if done { pending.removeAll() }
            if consumed == 0 && written == 0 { break }
            if pending.isEmpty && written < capacity { break }
        }
    }
}
