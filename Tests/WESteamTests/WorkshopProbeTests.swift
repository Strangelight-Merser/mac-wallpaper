import Foundation
import XCTest
@testable import WESteam

final class WorkshopProbeTests: XCTestCase {
    func header(_ names: [String]) -> Data {
        var d = Data(); d.appendLE(UInt32(8)); d.append(Data("PKGV0001".utf8)); d.appendLE(UInt32(names.count))
        for name in names {
            d.appendLE(UInt32(name.utf8.count)); d.append(Data(name.utf8)); d.appendLE(UInt32(0)); d.appendLE(UInt32(100))
        }
        return d
    }
    func testPartialAndMalformedHeaders() throws {
        let data = header(["models/a.mdl", "sounds/a.ogg"])
        for n in 0..<data.count { XCTAssertNil(try WorkshopPackageHeader.names(in: Data(data.prefix(n)), fileSize: UInt64(data.count + 100))) }
        XCTAssertEqual(try WorkshopPackageHeader.names(in: data, fileSize: UInt64(data.count + 100)), ["models/a.mdl", "sounds/a.ogg"])
        XCTAssertThrowsError(try WorkshopPackageHeader.names(in: data, fileSize: UInt64(data.count + 99)))
        var bad = data; bad[4] = 0
        XCTAssertThrowsError(try WorkshopPackageHeader.names(in: bad, fileSize: 1000))
    }
    func testOnlyHeaderChunksAndGlobalBudget() async throws {
        let h = header(["particles/a.json", "fonts/font.ttf"])
        let (plan, _, server) = try DownloadTests().setup([FileFixture(path: "scene.pkg", data: h + Data(repeating: 1, count: 100), chunks: [h, Data(repeating: 1, count: 100)])])
        let probe = WorkshopProbe(maxBytes: 2000, http: server.http, peek: { _, _, _, _, enough, cap in
            XCTAssertEqual(cap, 2000)
            XCTAssertTrue(try enough(h))
            return (h, 2000)
        })
        let result = try await probe.inspect(plan)
        XCTAssertTrue(result.packageHeadersComplete); XCTAssertTrue(result.names.contains("particles/a.json"))
        let used = await probe.reservedBytes
        XCTAssertEqual(used, 2000)
        let second = try await probe.inspect(plan)
        XCTAssertFalse(second.packageHeadersComplete)
        XCTAssertTrue(second.notes.contains { $0.contains("budget exhausted") })
        XCTAssertEqual(WorkshopProbe.initialBytes(plan), 65536)
        let count = await server.hosts.count
        XCTAssertEqual(count, 0)
    }
    func testGiveUpAndFailedServerAccounting() async throws {
        let h = header(["test"])
        let (original, _, server) = try DownloadTests().setup([FileFixture(path: "scene.pkg", data: h + Data(repeating: 0, count: 100))])
        let plan = try DownloadPlan(item: original.item, manifest: original.manifest, key: testKey,
            servers: [ContentServer(host: "first", vhost: "first"), ContentServer(host: "second", vhost: "second")])
        let probe = WorkshopProbe(maxBytes: 1000000, http: server.http, peek: { host, _, _, _, _, cap in
            if host.host == "first" {
                XCTAssertEqual(cap, 262144)
                throw ChunkPeekFailure(underlying: SteamError.transport, bytesRead: 100, retryable: true)
            }
            XCTAssertEqual(cap, 262044)
            return (Data(h.prefix(10)), cap)
        })
        let result = try await probe.inspect(plan)
        XCTAssertFalse(result.packageHeadersComplete)
        XCTAssertTrue(result.notes.contains { $0.contains("peek limit") })
        let used = await probe.reservedBytes, count = await server.hosts.count
        XCTAssertEqual(used, 262144); XCTAssertEqual(count, 0)
    }
    func testFailureIsChargedAndNeverRetried() async throws {
        let data = Data("{}".utf8)
        let (plan, _, server) = try DownloadTests().setup([FileFixture(path: "scene.json", data: data)], failures: 1)
        let probe = WorkshopProbe(maxBytes: plan.networkBytes, http: server.http)
        do { _ = try await probe.inspect(plan); XCTFail("expected network failure") }
        catch { XCTAssertEqual(error as? SteamError, .transport) }
        let reserved = await probe.reservedBytes, requests = await server.hosts.count
        XCTAssertEqual(reserved, plan.networkBytes); XCTAssertEqual(requests, 1)
        let result = try await probe.inspect(plan)
        XCTAssertTrue(result.jsonFiles.isEmpty)
        let finalRequests = await server.hosts.count
        XCTAssertEqual(finalRequests, 1)
    }
    func testStandaloneJSONZeroBudgetAndSingleChunkPackage() async throws {
        let data = Data("{\"objects\":[]}".utf8)
        let h = header([])
        let (plan, _, server) = try DownloadTests().setup([FileFixture(path: "scene.json", data: data), FileFixture(path: "scene.pkg", data: h)])
        let empty = WorkshopProbe(maxBytes: 0, http: server.http)
        let skipped = try await empty.inspect(plan)
        XCTAssertFalse(skipped.packageHeadersComplete); XCTAssertTrue(skipped.jsonFiles.isEmpty)
        let requests = await server.hosts.count
        XCTAssertEqual(requests, 0)
        let probe = WorkshopProbe(maxBytes: plan.networkBytes, http: server.http, peek: { _, _, _, _, _, cap in (h, min(cap, 16)) })
        let result = try await probe.inspect(plan)
        XCTAssertEqual(result.jsonFiles["scene.json"], data); XCTAssertTrue(result.packageHeadersComplete)
        let count = await server.hosts.count
        XCTAssertEqual(count, 1)
    }
}
