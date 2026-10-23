import Foundation
import XCTest
@testable import WESteam

final class WorkshopQueryTests: XCTestCase {
    func testEncodingAllSortsAndPaging() throws {
        let sorts: [(WorkshopQuery.Sort, UInt64)] = [(.popular, 0), (.recent, 1), (.trend(days: 7), 3),
            (.mostSubscribed, 9), (.textRelevance, 12), (.updated, 21)]
        for (sort, type) in sorts {
            let p = try ProtoReader(WorkshopQuery(sort: sort, searchText: "夜空 & stars", requiredTags: ["Scene", "Everyone"],
                excludedTags: ["Mature", "Questionable"], pageSize: 23).request(cursor: "next+/="))
            XCTAssertEqual(p.uint(1), type); XCTAssertEqual(p.uint(3), 23)
            XCTAssertEqual(p.uint(4), 431960); XCTAssertEqual(p.uint(5), 431960)
            XCTAssertEqual(p.repeated(6).map { String(decoding: $0, as: UTF8.self) }, ["Scene", "Everyone"])
            XCTAssertEqual(p.repeated(7).count, 2); XCTAssertEqual(p.uint(8), 1)
            XCTAssertEqual(p.string(11), "夜空 & stars"); XCTAssertEqual(p.string(39), "next+/=")
            XCTAssertFalse(p.contains(2))
            for f in [17, 18, 20, 22, 32, 37, 38] { XCTAssertEqual(p.uint(f), 1) }
            if type == 3 { XCTAssertEqual(p.uint(14), 7) }
        }
        for n in [0, 101, -1] { XCTAssertThrowsError(try WorkshopQuery(pageSize: n).request(cursor: "*")) }
        XCTAssertThrowsError(try WorkshopQuery(sort: .trend(days: 8)).request(cursor: "*"))
    }
    func testParsingMetadataPreviewsCursorAndMissingFields() throws {
        var item = ProtoWriter(); item.uint(1, 1); item.uint(2, 123); item.fixed64(3, testSteamID)
        item.uint(5, 431960); item.uint(8, 456); item.fixed64(14, 789); item.string(16, "Title")
        item.string(18, "Short"); item.uint(19, 100); item.uint(20, 200); item.uint(36, 10); item.uint(37, 20)
        for name in ["Scene", "Everyone", "Anime"] { var t = ProtoWriter(); t.string(1, name); item.bytes(52, t.data) }
        var preview = ProtoWriter(); preview.string(3, "https://example.invalid/image"); preview.uint(7, 0); item.bytes(51, preview.data)
        var votes = ProtoWriter(); votes.fixed32(1, Float(0.75).bitPattern); votes.uint(2, 30); votes.uint(3, 2); item.bytes(55, votes.data)
        var p = ProtoWriter(); p.uint(1, 100); p.bytes(2, item.data); p.string(3, "next")
        let page = try WorkshopPage.parse(p.data), value = try XCTUnwrap(page.items.first)
        XCTAssertEqual(page.total, 100); XCTAssertEqual(page.nextCursor, "next")
        XCTAssertEqual(value.kind, .scene); XCTAssertEqual(value.rating, .everyone)
        XCTAssertEqual(value.creatorID, testSteamID); XCTAssertEqual(value.subscriptions, 10); XCTAssertEqual(value.favorites, 20)
        XCTAssertEqual(value.voteScore, 0.75); XCTAssertEqual(value.votesUp, 30); XCTAssertEqual(value.votesDown, 2)
        XCTAssertEqual(value.shortDescription, "Short"); XCTAssertEqual(value.contentManifestID, 789)
        XCTAssertEqual(value.previewURL?.absoluteString, "https://example.invalid/image")
        var sparse = ProtoWriter(); sparse.uint(2, 7)
        var response = ProtoWriter(); response.uint(1, 1); response.bytes(2, sparse.data)
        let missing = try WorkshopPage.parse(response.data).items[0]
        XCTAssertNil(missing.kind); XCTAssertNil(missing.voteScore); XCTAssertEqual(missing.result, 2)
        XCTAssertThrowsError(try WorkshopPage.parse(Data()))
        XCTAssertThrowsError(try WorkshopPage.parse(Data([0xff])))
        var bad = ProtoWriter(); bad.uint(1, 1); bad.bytes(2, Data())
        XCTAssertThrowsError(try WorkshopPage.parse(bad.data))
    }
    func testOldJSONAndPreviewURL() throws {
        var value = item()
        value.previewURL = URL(string: "https://example.invalid/a?token=x&imw=999&imh=999&ima=crop#end")
        let url = try XCTUnwrap(value.previewURL(width: 320, height: 180))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.queryItems?.filter { $0.name == "imw" }.map(\.value), ["320"])
        XCTAssertTrue(parts.queryItems?.contains(URLQueryItem(name: "ima", value: "fit")) == true)
        XCTAssertTrue(parts.queryItems?.contains(URLQueryItem(name: "token", value: "x")) == true)
        XCTAssertEqual(parts.fragment, "end"); XCTAssertNil(value.previewURL(width: 0, height: 180))
        let data = try JSONEncoder().encode(value)
        let old = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(old["creatorID"])
        XCTAssertEqual(try JSONDecoder().decode(WorkshopItem.self, from: data), value)
    }
    func testCMSubscriptionsErrorsAndDisconnectedQuery() async throws {
        let fake = FakeCM(), client = SteamCMClient(machineName: "offline", http: directoryHTTP()) { _ in fake.connection }
        let browser = WorkshopBrowser(client: client)
        do { _ = try await browser.query(WorkshopQuery()); XCTFail() }
        catch { XCTAssertEqual(error as? SteamError, .disconnected) }
        try await client.connect(); _ = try await client.logOn(testTokens())
        try await browser.subscribe(123); try await browser.unsubscribe(456)
        let sent = await fake.sent.filter { $0.message == EMsg.serviceCall.rawValue }
        XCTAssertEqual(sent.count, 2)
        for (packet, id) in zip(sent, [UInt64(123), 456]) {
            let p = try ProtoReader(packet.body)
            XCTAssertEqual(p.uint(1), id); XCTAssertEqual(p.uint(2), 1); XCTAssertEqual(p.uint(3), 431960); XCTAssertEqual(p.uint(4), 1)
        }
        for result in [5, 15, 2] {
            await fake.configure(service: result)
            do { try await browser.subscribe(123); XCTFail() } catch { XCTAssertEqual(error as? SteamError, .result(result)) }
            do { try await browser.unsubscribe(123); XCTFail() } catch { XCTAssertEqual(error as? SteamError, .result(result)) }
            do { _ = try await browser.query(WorkshopQuery()); XCTFail() } catch { XCTAssertEqual(error as? SteamError, .result(result)) }
        }
        await client.disconnect()
    }
}
