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
        let parts = [Data(h.prefix(20)), Data(h.dropFirst(20)), Data(repeating: 1, count: 100)]
        let (plan, _, server) = try DownloadTests().setup([FileFixture(path: "scene.pkg", data: parts.reduce(Data(), +), chunks: parts)])
        let budget = Int64(plan.manifest.files[0].chunks.prefix(2).reduce(0) { $0 + $1.compressedSize })
        let probe = WorkshopProbe(maxBytes: budget, http: server.http)
        let result = try await probe.inspect(plan)
        XCTAssertTrue(result.packageHeadersComplete); XCTAssertTrue(result.names.contains("particles/a.json"))
        let requests = await server.hosts.count, used = await probe.reservedBytes
        XCTAssertEqual(requests, 2); XCTAssertEqual(used, budget)
        let second = try await probe.inspect(plan)
        XCTAssertFalse(second.packageHeadersComplete)
        let count = await server.hosts.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(WorkshopProbe.initialBytes(plan), Int64(plan.manifest.files[0].chunks[0].compressedSize))
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
        let probe = WorkshopProbe(maxBytes: plan.networkBytes, http: server.http)
        let result = try await probe.inspect(plan)
        XCTAssertEqual(result.jsonFiles["scene.json"], data); XCTAssertFalse(result.packageHeadersComplete)
        let count = await server.hosts.count
        XCTAssertEqual(count, 1)
    }
}
