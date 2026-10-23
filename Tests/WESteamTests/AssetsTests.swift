import Foundation
import XCTest
import WEFormat
@testable import WESteam

private func appText(_ depots: String, build: UInt64 = 123) -> String {
    "\"appinfo\" { \"depots\" { \"branches\" { \"public\" { \"buildid\" \"\(build)\" } } \(depots) } }"
}

private func productReply(_ text: String, missingToken: Bool = false) -> Data {
    var app = ProtoWriter(); app.uint(1, 431960); app.uint(3, missingToken ? 1 : 0)
    app.bytes(5, Data((text + "\0").utf8))
    var p = ProtoWriter(); p.bytes(1, app.data); return p.data
}

private actor AssetsCM {
    nonisolated let stream: AsyncThrowingStream<Data, Error>
    nonisolated let sink: AsyncThrowingStream<Data, Error>.Continuation
    var sent: [CMPacket] = []
    var text: String
    init(_ text: String) {
        self.text = text
        (stream, sink) = AsyncThrowingStream.makeStream()
    }
    func setInfo(_ text: String) { self.text = text }
    func send(_ data: Data) throws {
        let packet = try CMPacket(data); sent.append(packet)
        var h = CMHeader(); h.steamID = testSteamID; h.sessionID = 123; h.targetJob = packet.header.sourceJob
        var p = ProtoWriter()
        switch packet.message {
        case EMsg.logOn.rawValue:
            p.uint(1, 1); p.uint(3, 60)
            sink.yield(CMPacket(.logOnResponse, header: h, body: p.data).encoded())
        case EMsg.picsAccessToken.rawValue:
            var token = ProtoWriter(); token.uint(1, 431960); token.uint(2, UInt64.max)
            p.bytes(3, token.data)
            sink.yield(CMPacket(.picsAccessTokenResponse, header: h, body: p.data).encoded())
        case EMsg.picsProductInfo.rawValue:
            var pending = ProtoWriter(); pending.uint(6, 1)
            sink.yield(CMPacket(.picsProductInfoResponse, header: h, body: productReply(text) + pending.data).encoded())
            sink.yield(CMPacket(.picsProductInfoResponse, header: h).encoded())
        case EMsg.depotKey.rawValue:
            p.uint(1, 1); p.uint(2, try ProtoReader(packet.body).uint(1)); p.bytes(3, testKey)
            sink.yield(CMPacket(.depotKeyResponse, header: h, body: p.data).encoded())
        case EMsg.serviceCall.rawValue:
            p.uint(1, 777); h.result = 1
            sink.yield(CMPacket(.serviceResponse, header: h, body: p.data).encoded())
        default: break
        }
    }
    nonisolated var connection: CMConnection {
        CMConnection(send: { try await self.send($0) }, receive: {
            for try await data in self.stream { return data }
            throw SteamError.disconnected
        }, close: { self.sink.finish() })
    }
}

final class AssetsTests: XCTestCase {
    private let servers = [ContentServer(host: "one.invalid", vhost: "one.invalid")]
    private let session = SteamSession(steamID: testSteamID, cellID: 0, ipCountry: "")

    private func plan(_ fixtures: [FileFixture], id: UInt64 = 99) throws -> (WEAssetsPlan, [String: Data]) {
        let (data, chunks) = try manifestData(fixtures, encrypted: true, manifestID: id)
        let manifest = try ContentManifest(data: data, key: testKey).assetsOnly()
        return (try WEAssetsPlan(buildID: id + 1, content: [ContentDepot(manifest: manifest, key: testKey, servers: servers)]), chunks)
    }
    private func downloader(_ http: SteamHTTP) -> WEAssetsDownloader {
        let client = SteamCMClient(machineName: "offline", http: directoryHTTP()) { _ in throw SteamError.transport }
        return WEAssetsDownloader(client: client, session: session, http: http)
    }
    func testPICSDecodingAndDepotSelection() throws {
        let text = appText("""
        "10" { "config" { "oslist" "linux, windows" } "manifests" { "public" { "gid" "18446744073709551615" } } }
        "11" { "manifests" { "public" "102" } }
        "12" { "config" { "oslist" "linux" } "manifests" { "public" "103" } }
        "13" { "sharedinstall" "1" "manifests" { "public" "104" } }
        "14" { "depotfromapp" "9" "manifests" { "public" "105" } }
        "15" { "dlcappid" "9" "manifests" { "public" "106" } }
        "16" { "manifests" { "beta" "107" } }
        "17" { "sharedinstall" "0" "dlcappid" "0" "manifests" { "public" "108" } }
        "18" { "config" { "oslist" "windows64" } "manifests" { "public" "109" } }
        "19" { "manifests" { "public" "0" } }
        "20" { "manifests" { "public" "bad" } }
        """, build: 456)
        let info = try AssetsAppInfo(PICS.appInfo(productReply(text), appID: 431960))
        XCTAssertEqual(info.buildID, 456)
        XCTAssertEqual(info.depots.map(\.depotID), [10, 11, 17])
        XCTAssertEqual(info.depots.map(\.manifestID), [.max, 102, 108])
        XCTAssertThrowsError(try AssetsAppInfo(VDF.parse("\"depots\" { }"))) {
            XCTAssertEqual($0 as? SteamError, .malformed("Wallpaper Engine has no public branch build ID"))
        }
        XCTAssertThrowsError(try AssetsAppInfo(PICS.appInfo(productReply(appText("")), appID: 431960)))
        XCTAssertThrowsError(try PICS.appInfo(productReply(text, missingToken: true), appID: 431960))
        XCTAssertThrowsError(try PICS.appInfo(Data(), appID: 431960))
        XCTAssertThrowsError(try PICS.appInfo(productReply("bad"), appID: 431960))
        var denied = ProtoWriter(); denied.uint(4, 431960)
        XCTAssertThrowsError(try PICS.accessToken(denied.data, appID: 431960))
        var packed = ProtoWriter(); packed.varint(431960)
        var packedDenied = ProtoWriter(); packedDenied.bytes(4, packed.data)
        XCTAssertThrowsError(try PICS.accessToken(packedDenied.data, appID: 431960))
        XCTAssertEqual(try PICS.accessToken(Data(), appID: 431960), 0)
    }
    func testFilterSizesAndReceiptRoundTrip() throws {
        let (plan, chunks) = try plan([
            FileFixture(path: "ASSETS", data: Data(), flags: 64),
            FileFixture(path: "ASSETS\\shaders", data: Data(), flags: 64),
            FileFixture(path: "ASSETS\\shaders\\test", data: Data("shader".utf8)),
            FileFixture(path: "assets/empty", data: Data()),
            FileFixture(path: "assets/link", data: Data(), link: "outside"),
            FileFixture(path: "assets-other/excluded", data: Data("excluded".utf8)),
            FileFixture(path: "bin/assets/excluded", data: Data("excluded".utf8)),
        ])
        XCTAssertEqual(plan.files, 2); XCTAssertEqual(plan.diskBytes, 6)
        XCTAssertEqual(plan.networkBytes, Int64(chunks[ChunkCodec.sha1(Data("shader".utf8)).hex]!.count))
        XCTAssertEqual(plan.content[0].manifest.files.map(\.path), ["shaders", "shaders/test", "empty", "link"])
        let receipt = WEAssetsReceipt(plan)
        XCTAssertEqual(try JSONDecoder().decode(WEAssetsReceipt.self, from: JSONEncoder().encode(receipt)), receipt)
        XCTAssertEqual(receipt.depotID, 431960); XCTAssertEqual(receipt.manifestID, 99)
        XCTAssertEqual(receipt.buildID, 100); XCTAssertEqual(receipt.files, 2); XCTAssertEqual(receipt.bytes, 6)
        XCTAssertThrowsError(try self.plan([FileFixture(path: "program.exe", data: Data())]))
        XCTAssertThrowsError(try self.plan([FileFixture(path: "assets/.steam-manifest.json", data: Data())]))
    }
    func testUpdateDiffUsesFileHashesAndIncludesNewFiles() throws {
        let (old, _) = try plan([
            FileFixture(path: "assets/keep", data: Data("same".utf8)),
            FileFixture(path: "assets/change", data: Data("before".utf8)),
            FileFixture(path: "assets/deleted", data: Data("gone".utf8)),
        ])
        let (new, _) = try plan([
            FileFixture(path: "assets/keep", data: Data("same".utf8)),
            FileFixture(path: "assets/change", data: Data("after".utf8)),
            FileFixture(path: "assets/new", data: Data("new".utf8)),
        ], id: 100)
        let diff = try WEAssetsReceipt(old).changes(in: new)
        XCTAssertEqual(diff.diskBytes, 8)
        let expected = try ContentSizes(new.content[0].manifest.files.filter { $0.path != "keep" })
        XCTAssertEqual(diff.networkBytes, expected.networkBytes)
        XCTAssertEqual(try WEAssetsReceipt(new).changes(in: new).networkBytes, 0)
    }
    func testDownloadUpdateReusesVerifiedDestinationAndPartial() async throws {
        let keep = Data("keep".utf8), changed = Data("changed".utf8), fresh = Data("fresh".utf8)
        let (plan, chunks) = try plan([
            FileFixture(path: "assets/sub/keep", data: keep),
            FileFixture(path: "assets/change", data: changed),
            FileFixture(path: "assets/new", data: fresh),
        ])
        let server = ChunkServer(chunks: chunks)
        let root = try tempDirectory(), dest = root.appendingPathComponent("assets")
        defer { try? FileManager.default.removeItem(at: root) }
        let partial = URL(fileURLWithPath: dest.path + ".partial")
        try FileManager.default.createDirectory(at: dest.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try keep.write(to: dest.appendingPathComponent("sub/keep"))
        try Data("old".utf8).write(to: dest.appendingPathComponent("change"))
        try Data("gone".utf8).write(to: dest.appendingPathComponent("deleted"))
        try fresh.write(to: partial.appendingPathComponent("new"))
        try Data("stale".utf8).write(to: partial.appendingPathComponent("obsolete"))
        let required = Int64(chunks[ChunkCodec.sha1(changed).hex]!.count)
        let result = try await downloader(server.http).download(plan, to: dest, maxBytes: required) { _ in }
        XCTAssertEqual(result.files, 3)
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("sub/keep")), keep)
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("change")), changed)
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("new")), fresh)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("deleted").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("obsolete").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent(".steam-manifest.json").path))
        let receipt = try JSONDecoder().decode(WEAssetsReceipt.self, from: Data(contentsOf: WEAssetsDownloader.receiptURL(for: dest)))
        XCTAssertEqual(receipt, WEAssetsReceipt(plan))
        let requests = await server.hosts.count
        XCTAssertEqual(requests, 1)
        _ = try await downloader(server.http).download(plan, to: dest, maxBytes: 0) { _ in }
        let after = await server.hosts.count
        XCTAssertEqual(after, 1)
    }
    func testLimitBeforeWritingAndZstdErrorPreservesDestination() async throws {
        let plain = Data("content".utf8)
        let (plan, _) = try plan([FileFixture(path: "assets/file", data: plain)])
        let root = try tempDirectory(), dest = root.appendingPathComponent("assets")
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = HTTPQueue([])
        do { _ = try await downloader(queue.http).download(plan, to: dest, maxBytes: 0) { _ in }; XCTFail() }
        catch { XCTAssertEqual(error as? SteamError, .tooLarge(plan.networkBytes)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path + ".partial"))
        let count = await queue.requests.count
        XCTAssertEqual(count, 0)
        let encoded = try encrypt(Data("VSZa".utf8))
        let file = plan.content[0].manifest.files[0], chunk = file.chunks[0]
        let unsupported = ContentManifest.File(path: file.path, size: file.size, flags: 0, shaFilename: file.shaFilename,
            shaContent: file.shaContent, chunks: [.init(sha: chunk.sha, crc: chunk.crc, offset: 0,
            originalSize: chunk.originalSize, compressedSize: encoded.count)], linkTarget: "")
        let manifest = ContentManifest(depotID: 431960, manifestID: 99, files: [unsupported])
        let bad = try WEAssetsPlan(buildID: 100, content: [.init(manifest: manifest, key: testKey, servers: servers)])
        let server = ChunkServer(chunks: [chunk.sha.hex: encoded])
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: dest.appendingPathComponent("old"))
        do { _ = try await downloader(server.http).download(bad, to: dest, maxBytes: .max) { _ in }; XCTFail() }
        catch { XCTAssertEqual(error as? SteamError, .unsupportedCompression("zstd")) }
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("old")), Data("old".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: WEAssetsDownloader.receiptURL(for: dest).path))
        let attempts = await server.hosts.count
        XCTAssertEqual(attempts, 1)
    }
    func testPICSPlanAndUpdateCheckFetchOnlyMetadata() async throws {
        let info = appText("\"431960\" { \"manifests\" { \"public\" { \"gid\" \"99\" } } }")
        let fake = AssetsCM(info)
        let client = SteamCMClient(machineName: "offline", http: directoryHTTP()) { _ in fake.connection }
        try await client.connect(); let session = try await client.logOn(testTokens())
        let (manifest, _) = try manifestData([FileFixture(path: "assets/file", data: Data("fixture".utf8))])
        let compressed = try zip(manifest, compressed: true)
        let http = SteamHTTP { request in
            if request.url!.path.contains("GetServersForSteamPipe") {
                return response(request, Data(#"{"response":{"servers":[{"type":"CDN","host":"one.invalid","https_support":"mandatory"}]}}"#.utf8))
            }
            XCTAssertEqual(request.url!.path, "/depot/431960/manifest/99/5/777")
            return response(request, compressed)
        }
        let downloader = WEAssetsDownloader(client: client, session: session, http: http)
        let plan = try await downloader.plan()
        XCTAssertEqual(plan.files, 1); XCTAssertEqual(plan.diskBytes, 7)
        let packets = await fake.sent
        let access = try XCTUnwrap(packets.first { $0.message == 8905 })
        XCTAssertEqual(try ProtoReader(access.body).uint(2), 431960)
        let product = try XCTUnwrap(packets.first { $0.message == 8903 })
        let app = try ProtoReader(ProtoReader(product.body).bytes(2))
        XCTAssertEqual(app.uint(1), 431960); XCTAssertEqual(app.uint(2), .max)
        let root = try tempDirectory(), dest = root.appendingPathComponent("assets")
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONEncoder().encode(WEAssetsReceipt(plan)).write(to: WEAssetsDownloader.receiptURL(for: dest))
        let metadataOnly = WEAssetsDownloader(client: client, session: session, http: HTTPQueue([]).http)
        if case .upToDate = try await metadataOnly.checkForUpdate(receiptAt: dest) {} else { XCTFail() }
        let (old, _) = try self.plan([FileFixture(path: "assets/file", data: Data("old".utf8))], id: 98)
        try JSONEncoder().encode(WEAssetsReceipt(old)).write(to: WEAssetsDownloader.receiptURL(for: dest))
        switch try await downloader.checkForUpdate(receiptAt: dest) {
        case .upToDate: XCTFail()
        case .available(let updated, let network, let disk):
            XCTAssertEqual(updated.manifestID, 99); XCTAssertEqual(network, plan.networkBytes); XCTAssertEqual(disk, 7)
        }
        await client.disconnect()
    }
    func testAppDepotManifestRequestsUseDepotIDAndPublicBranch() async throws {
        let fake = AssetsCM(appText("\"431961\" { \"manifests\" { \"public\" \"99\" } }"))
        let client = SteamCMClient(machineName: "offline", http: directoryHTTP()) { _ in fake.connection }
        try await client.connect(); let session = try await client.logOn(testTokens())
        let (source, _) = try manifestData([FileFixture(path: "assets/file", data: Data("fixture".utf8))])
        var cursor = ByteCursor(source), container = Data()
        while cursor.remaining > 0 {
            let magic = try cursor.integer(UInt32.self)
            container.appendLE(magic)
            if magic == 0x32c415ab { break }
            var section = try cursor.read(Int(cursor.integer(UInt32.self)))
            if magic == 0x1f4812be {
                var metadata = ProtoWriter(); metadata.uint(1, 431961); metadata.uint(2, 99)
                section = metadata.data
            }
            container.appendLE(UInt32(section.count)); container.append(section)
        }
        let packed = try zip(container, compressed: true)
        let http = SteamHTTP { request in
            if request.url!.path.contains("GetServersForSteamPipe") {
                return response(request, Data(#"{"response":{"servers":[{"type":"CDN","host":"one.invalid","https_support":"mandatory"}]}}"#.utf8))
            }
            XCTAssertEqual(request.url!.path, "/depot/431961/manifest/99/5/777")
            return response(request, packed)
        }
        let plan = try await WEAssetsDownloader(client: client, session: session, http: http).plan()
        XCTAssertEqual(plan.depotID, 431961)
        let packets = await fake.sent
        let key = try ProtoReader(XCTUnwrap(packets.first { $0.message == EMsg.depotKey.rawValue }).body)
        XCTAssertEqual(key.uint(1), 431961); XCTAssertEqual(key.uint(2), 431960)
        let request = try ProtoReader(XCTUnwrap(packets.first { $0.header.method == "ContentServerDirectory.GetManifestRequestCode#1" }).body)
        XCTAssertEqual(request.uint(1), 431960); XCTAssertEqual(request.uint(2), 431961)
        XCTAssertEqual(request.uint(3), 99); XCTAssertEqual(request.string(4), "public")
        await client.disconnect()
    }
    func testMultipleDepotsAndConflicts() async throws {
        let (first, firstChunks) = try plan([FileFixture(path: "assets/one", data: Data("one".utf8))])
        let (second, secondChunks) = try plan([FileFixture(path: "assets/two", data: Data("two".utf8))], id: 101)
        let other = ContentDepot(manifest: ContentManifest(depotID: 431961, manifestID: 101,
            files: second.content[0].manifest.files), key: testKey, servers: servers)
        let combined = try WEAssetsPlan(buildID: 1, content: first.content + [other])
        XCTAssertEqual(combined.depots.map(\.depotID), [431960, 431961])
        XCTAssertEqual(combined.files, 2)
        XCTAssertEqual(combined.networkBytes, first.networkBytes + second.networkBytes)
        let chunks = firstChunks.merging(secondChunks) { a, _ in a }
        let http = SteamHTTP { request in
            let expectedDepot = request.url!.lastPathComponent == ChunkCodec.sha1(Data("one".utf8)).hex ? "431960" : "431961"
            XCTAssertTrue(request.url!.path.hasPrefix("/depot/\(expectedDepot)/chunk/"))
            return response(request, try XCTUnwrap(chunks[request.url!.lastPathComponent]))
        }
        let root = try tempDirectory(), dest = root.appendingPathComponent("assets")
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await downloader(http).download(combined, to: dest, maxBytes: combined.networkBytes) { _ in }
        XCTAssertEqual(result.files, 2)
        XCTAssertThrowsError(try WEAssetsPlan(buildID: 1, content: first.content + first.content))
    }
}
