import Foundation
import XCTest
@testable import WESteam

actor ChunkServer {
    let chunks: [String: Data]
    var hosts: [String] = []
    var active = 0
    var peak = 0
    var failures: Int
    init(chunks: [String: Data], failures: Int = 0) { self.chunks = chunks; self.failures = failures }
    func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        hosts.append(request.url!.host!)
        active += 1; peak = max(peak, active)
        defer { active -= 1 }
        if failures > 0 { failures -= 1; throw SteamError.transport }
        try await Task.sleep(for: .milliseconds(10))
        guard let data = chunks[request.url!.lastPathComponent] else { throw SteamError.malformed("unexpected chunk") }
        return response(request, data)
    }
    nonisolated var http: SteamHTTP { SteamHTTP { try await self.load($0) } }
}

final class DownloadTests: XCTestCase {
    func setup(_ fixtures: [FileFixture], failures: Int = 0) throws -> (DownloadPlan, WorkshopDownloader, ChunkServer) {
        let (bytes, chunks) = try manifestData(fixtures, encrypted: true)
        let manifest = try ContentManifest(data: bytes, key: testKey)
        let servers = [ContentServer(host: "one.invalid", vhost: "one.invalid"), ContentServer(host: "two.invalid", vhost: "two.invalid")]
        let plan = try DownloadPlan(item: item(), manifest: manifest, key: testKey, servers: servers)
        let stub = ChunkServer(chunks: chunks, failures: failures)
        let client = SteamCMClient(machineName: "offline", http: directoryHTTP()) { _ in throw SteamError.transport }
        let downloader = WorkshopDownloader(client: client, session: SteamSession(steamID: testSteamID, cellID: 0, ipCountry: ""),
                                             http: stub.http)
        return (plan, downloader, stub)
    }
    func testDownloadConcurrencyEmptyFilesDirectoriesAndAtomicReplace() async throws {
        let chunks = (0..<12).map { Data(repeating: UInt8($0), count: 1000) }, plain = chunks.reduce(Data(), +)
        let (plan, downloader, server) = try setup([
            FileFixture(path: "folder", data: Data(), flags: 64),
            FileFixture(path: "folder/file", data: plain, chunks: chunks),
            FileFixture(path: "empty", data: Data()),
            FileFixture(path: "link", data: Data(), link: "folder/file"),
        ])
        let root = try tempDirectory(), dest = root.appendingPathComponent("wallpaper")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
        try Data("old".utf8).write(to: dest.appendingPathComponent("old"))
        let result = try await downloader.download(plan, to: dest, maxBytes: plan.networkBytes) { _ in }
        XCTAssertEqual(result.files, 2); XCTAssertEqual(result.warnings.count, 1)
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("folder/file")), plain)
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("empty")), Data())
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("old").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("link").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path + ".partial"))
        let receipt = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: dest.appendingPathComponent(".steam-manifest.json")))
        XCTAssertEqual(receipt["publishedFileID"].uint, 123); XCTAssertEqual(receipt["manifestID"].uint, 99)
        XCTAssertEqual(receipt["files"].uint, 2)
        let peak = await server.peak
        XCTAssertEqual(peak, 6)
    }
    func testResumeSkipsVerifiedFileAndRemovesStalePartial() async throws {
        let plain = Data("verified".utf8)
        let (plan, downloader, server) = try setup([FileFixture(path: "file", data: plain)])
        let root = try tempDirectory(), dest = root.appendingPathComponent("wallpaper")
        defer { try? FileManager.default.removeItem(at: root) }
        let partial = URL(fileURLWithPath: dest.path + ".partial")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: false)
        try plain.write(to: partial.appendingPathComponent("file"))
        try Data("obsolete".utf8).write(to: partial.appendingPathComponent("stale"))
        _ = try await downloader.download(plan, to: dest, maxBytes: plan.networkBytes) { _ in }
        let requests = await server.hosts.count
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("file")), plain)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("stale").path))
    }
    func testLimitRefusesBeforeWritingAndRetryRotatesServers() async throws {
        let (plan, downloader, server) = try setup([FileFixture(path: "file", data: Data("retry".utf8))], failures: 1)
        let root = try tempDirectory(), dest = root.appendingPathComponent("wallpaper")
        defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await downloader.download(plan, to: dest, maxBytes: 0) { _ in }; XCTFail("expected byte limit") }
        catch { XCTAssertEqual(error as? SteamError, .tooLarge(plan.networkBytes)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path + ".partial"))
        _ = try await downloader.download(plan, to: dest, maxBytes: .max) { _ in }
        let hosts = await server.hosts
        XCTAssertEqual(hosts, ["one.invalid", "two.invalid"])
    }
    func testFailurePreservesDestinationAndBoundsRetries() async throws {
        let (plan, downloader, server) = try setup([FileFixture(path: "file", data: Data("fail".utf8))], failures: 10)
        let root = try tempDirectory(), dest = root.appendingPathComponent("wallpaper")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
        let old = dest.appendingPathComponent("old"); try Data([123]).write(to: old)
        do { _ = try await downloader.download(plan, to: dest, maxBytes: .max) { _ in }; XCTFail("expected failure") }
        catch { XCTAssertEqual(error as? SteamError, .transport) }
        XCTAssertEqual(try Data(contentsOf: old), Data([123]))
        let requests = await server.hosts.count
        XCTAssertEqual(requests, 4)
    }
    func testHashMismatchAndPartialSymlinkAreRejected() async throws {
        let (plan, downloader, _) = try setup([FileFixture(path: "file", data: Data("actual".utf8),
                                                         contentHash: ChunkCodec.sha1(Data("wrong".utf8)))])
        let root = try tempDirectory(), dest = root.appendingPathComponent("wallpaper")
        defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await downloader.download(plan, to: dest, maxBytes: plan.networkBytes) { _ in }; XCTFail("expected hash failure") }
        catch { XCTAssertEqual(error as? SteamError, .malformed("file SHA-1 or size")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        let partial = URL(fileURLWithPath: dest.path + ".partial")
        try FileManager.default.removeItem(at: partial.appendingPathComponent("file"))
        try FileManager.default.createSymbolicLink(at: partial.appendingPathComponent("file"), withDestinationURL: root.appendingPathComponent("outside"))
        do { _ = try await downloader.download(plan, to: dest, maxBytes: plan.networkBytes) { _ in }; XCTFail("expected symlink failure") }
        catch { XCTAssertEqual(error as? SteamError, .malformed("symlink in partial directory")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside").path))
    }
    func testPlannerFetchesManifestWithoutChunks() async throws {
        let (container, _) = try manifestData([FileFixture(path: "file", data: Data("planned".utf8))], encrypted: true)
        let zipped = try zip(container, compressed: true), fake = FakeCM()
        var code = ProtoWriter(); code.uint(1, 777)
        await fake.configure(body: code.data)
        let client = SteamCMClient(machineName: "offline", http: directoryHTTP()) { _ in fake.connection }
        try await client.connect()
        let session = try await client.logOn(testTokens())
        let http = SteamHTTP { request in
            if request.url!.path.contains("GetServersForSteamPipe") {
                return response(request, Data(#"{"response":{"servers":[{"type":"CDN","host":"one.invalid","https_support":"mandatory"}]}}"#.utf8))
            }
            XCTAssertEqual(request.url?.path, "/depot/431960/manifest/99/5/777")
            return response(request, zipped)
        }
        let plan = try await WorkshopDownloader(client: client, session: session, http: http).plan(item())
        XCTAssertEqual(plan.diskBytes, 7); XCTAssertGreaterThan(plan.networkBytes, 0)
        let packets = await fake.sent
        let call = try XCTUnwrap(packets.first { $0.header.method == "ContentServerDirectory.GetManifestRequestCode#1" })
        let fields = try ProtoReader(call.body)
        XCTAssertEqual(fields.uint(1), 431960); XCTAssertEqual(fields.uint(2), 431960)
        XCTAssertEqual(fields.uint(3), 99); XCTAssertEqual(fields.string(4), "public")
        await client.disconnect()
    }
    func testServerFiltering() throws {
        let response = try json(#"{"servers":[{"type":"CDN","host":"valid","https_support":"optional","weighted_load":2},{"type":"SteamCache","host":"first","https_support":"mandatory","weighted_load":1},{"type":"CDN","host":"token","https_support":"mandatory","usetokenauth":1},{"type":"CDN","host":"proxy","https_support":"mandatory","use_as_proxy":true},{"type":"CDN","host":"restricted","https_support":"mandatory","allowed_app_ids":[431960]},{"type":"CDN","host":"http","https_support":"none"}]}"#)
        XCTAssertEqual(ContentServer.parse(response).map(\.host), ["first", "valid"])
    }
}
