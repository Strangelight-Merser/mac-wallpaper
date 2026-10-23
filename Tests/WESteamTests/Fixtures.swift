import CSteamSupport
import Foundation
import XCTest
@testable import WESteam

let testKey = Data(0..<32)
let testSteamID: UInt64 = 76561198000000001

func jwt(expires: TimeInterval = Date().timeIntervalSince1970 + 7200) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: ["sub": String(testSteamID), "aud": ["client"], "exp": expires, "iss": "steam"])
    let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "e30." + encoded + ".test"
}

func testTokens() throws -> SteamTokens {
    SteamTokens(accountName: "offline-fixture", steamID: testSteamID, refreshToken: try jwt(), accessToken: try jwt())
}

func encrypt(_ data: Data, padding: Bool = true) throws -> Data {
    let iv = Data(repeating: 42, count: 16)
    func crypt(_ data: Data, iv: Data, options: CCOptions) throws -> Data {
        var output = Data(count: data.count + 32), written = 0
        let capacity = output.count
        let status = data.withUnsafeBytes { input in
            testKey.withUnsafeBytes { key in
                iv.withUnsafeBytes { iv in
                    output.withUnsafeMutableBytes { out in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), options,
                                key.baseAddress, 32, iv.baseAddress, input.baseAddress, data.count,
                                out.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw SteamError.malformed("test encryption") }
        output.count = written
        return output
    }
    return try crypt(iv, iv: iv, options: CCOptions(kCCOptionECBMode)) +
        crypt(data, iv: iv, options: padding ? CCOptions(kCCOptionPKCS7Padding) : 0)
}

func deflate(_ data: Data, window: Int32) throws -> Data {
    var stream = z_stream()
    guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, window, 8, Z_DEFAULT_STRATEGY,
                       ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
        throw SteamError.malformed("test deflate init")
    }
    defer { deflateEnd(&stream) }
    var output = Data(count: data.count * 2 + 1024)
    let capacity = output.count
    let status = data.withUnsafeBytes { input in
        output.withUnsafeMutableBytes { out in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
            stream.avail_out = uInt(capacity)
            return CSteamSupport.deflate(&stream, Z_FINISH)
        }
    }
    guard status == Z_STREAM_END else { throw SteamError.malformed("test deflate") }
    output.count = Int(stream.total_out)
    return output
}

func vzip(_ data: Data) throws -> Data {
    var options = lzma_options_lzma()
    guard lzma_lzma_preset(&options, 6) == 0 else { throw SteamError.malformed("test LZMA preset") }
    var stream = lzma_stream()
    guard lzma_alone_encoder(&stream, &options) == LZMA_OK else { throw SteamError.malformed("test LZMA encoder") }
    defer { lzma_end(&stream) }
    var output = Data(count: data.count * 2 + 4096)
    let capacity = output.count
    let status = data.withUnsafeBytes { input in
        output.withUnsafeMutableBytes { out in
            stream.next_in = input.bindMemory(to: UInt8.self).baseAddress; stream.avail_in = data.count
            stream.next_out = out.bindMemory(to: UInt8.self).baseAddress; stream.avail_out = capacity
            return lzma_code(&stream, LZMA_FINISH)
        }
    }
    guard status == LZMA_STREAM_END else { throw SteamError.malformed("test LZMA encode") }
    output.count = Int(stream.total_out)
    // cdn_compression.js: 3-byte header, 4-byte opaque field, 5-byte properties, raw LZMA, footer.
    var result = Data("VZa".utf8); result.appendLE(UInt32(0))
    result.append(output.prefix(5)); result.append(output.dropFirst(13))
    result.appendLE(ChunkCodec.crc32(data)); result.appendLE(UInt32(data.count)); result.append(Data("zv".utf8))
    return result
}

func zip(_ data: Data, compressed: Bool, descriptor: Bool = false) throws -> Data {
    // adm-zip/util/constants.js: local/central/end headers.
    let payload = compressed ? try deflate(data, window: -15) : data
    let flags: UInt16 = descriptor ? 8 : 0, method: UInt16 = compressed ? 8 : 0
    let crc = ChunkCodec.crc32(data)
    var local = Data(); local.appendLE(UInt32(0x04034b50)); local.appendLE(UInt16(20))
    local.appendLE(flags); local.appendLE(method); local.appendLE(UInt32(0))
    local.appendLE(descriptor ? UInt32(0) : crc)
    local.appendLE(descriptor ? UInt32(0) : UInt32(payload.count))
    local.appendLE(descriptor ? UInt32(0) : UInt32(data.count))
    local.appendLE(UInt16(1)); local.appendLE(UInt16(0)); local.append(120); local.append(payload)
    if descriptor {
        local.appendLE(UInt32(0x08074b50)); local.appendLE(crc)
        local.appendLE(UInt32(payload.count)); local.appendLE(UInt32(data.count))
    }
    var central = Data(); central.appendLE(UInt32(0x02014b50)); central.appendLE(UInt16(20)); central.appendLE(UInt16(20))
    central.appendLE(flags); central.appendLE(method); central.appendLE(UInt32(0)); central.appendLE(crc)
    central.appendLE(UInt32(payload.count)); central.appendLE(UInt32(data.count)); central.appendLE(UInt16(1))
    central.append(Data(repeating: 0, count: 16)); central.append(120)
    var end = Data(); end.appendLE(UInt32(0x06054b50)); end.appendLE(UInt32(0))
    end.appendLE(UInt16(1)); end.appendLE(UInt16(1)); end.appendLE(UInt32(central.count))
    end.appendLE(UInt32(local.count)); end.appendLE(UInt16(0))
    return local + central + end
}

struct FileFixture {
    var path: String
    var data: Data
    var flags: UInt32 = 0
    var link = ""
    var chunks: [Data] = []
    var contentHash: Data?
}

func manifestData(_ files: [FileFixture], encrypted: Bool = false, manifestID: UInt64 = 99) throws -> (Data, [String: Data]) {
    // content_manifest.proto fields; container constants in content_manifest.js.
    var payload = ProtoWriter(), responses: [String: Data] = [:]
    for file in files {
        var mapping = ProtoWriter()
        // Like Steam: base64 with line breaks, and the plaintext name is NUL-terminated.
        let name = encrypted ? try encrypt(Data((file.path + "\0").utf8)).base64EncodedString(options: .lineLength64Characters) + "\n" : file.path
        mapping.string(1, name); mapping.uint(2, UInt64(file.data.count)); mapping.uint(3, UInt64(file.flags))
        mapping.bytes(4, ChunkCodec.sha1(Data(file.path.utf8)))
        mapping.bytes(5, file.contentHash ?? ChunkCodec.sha1(file.data))
        let chunks = file.chunks.isEmpty && !file.data.isEmpty ? [file.data] : file.chunks
        var offset: UInt64 = 0
        for plain in chunks {
            let sha = ChunkCodec.sha1(plain), packed = try encrypt(zip(plain, compressed: true))
            responses[sha.hex] = packed
            var chunk = ProtoWriter(); chunk.bytes(1, sha); chunk.fixed32(2, ChunkCodec.crc32(plain))
            chunk.uint(3, offset); chunk.uint(4, UInt64(plain.count)); chunk.uint(5, UInt64(packed.count))
            mapping.bytes(6, chunk.data); offset += UInt64(plain.count)
        }
        if !file.link.isEmpty { mapping.string(7, file.link) }
        payload.bytes(1, mapping.data)
    }
    var meta = ProtoWriter(); meta.uint(1, 431960); meta.uint(2, manifestID); meta.uint(4, encrypted ? 1 : 0)
    var container = Data()
    for (magic, section): (UInt32, Data) in [(0x71f617d0, payload.data), (0x1f4812be, meta.data), (0x1b81b817, Data())] {
        container.appendLE(magic); container.appendLE(UInt32(section.count)); container.append(section)
    }
    container.appendLE(UInt32(0x32c415ab))
    return (container, responses)
}

func item() -> WorkshopItem {
    WorkshopItem(id: 123, appID: 431960, title: "Offline", fileSize: 0,
                 timeUpdated: Date(timeIntervalSince1970: 123456), contentManifestID: 99)
}

func json(_ string: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8)) }
func response(_ request: URLRequest, _ data: Data, status: Int = 200, headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
    (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
}

actor HTTPQueue {
    var requests: [URLRequest] = []
    var replies: [(Data, Int, [String: String])]
    init(_ replies: [(String, Int, [String: String])]) {
        self.replies = replies.map { (Data($0.0.utf8), $0.1, $0.2) }
    }
    func load(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw SteamError.malformed("unexpected offline request") }
        let reply = replies.removeFirst()
        return response(request, reply.0, status: reply.1, headers: reply.2)
    }
    nonisolated var http: SteamHTTP { SteamHTTP { try await self.load($0) } }
}

func tempDirectory() throws -> URL {
    let url = URL(fileURLWithPath: "/private/tmp/westeam-tests-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
