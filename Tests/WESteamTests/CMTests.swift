import Foundation
import XCTest
@testable import WESteam

actor FakeCM {
    nonisolated let stream: AsyncThrowingStream<Data, Error>
    nonisolated let sink: AsyncThrowingStream<Data, Error>.Continuation
    var sent: [CMPacket] = []
    var logonResult = 1
    var serviceResult = 1
    var serviceBody = Data()
    var ignoreServices = false
    init() { (stream, sink) = AsyncThrowingStream.makeStream() }
    func configure(logon: Int = 1, service: Int = 1, body: Data = Data(), ignore: Bool = false) {
        logonResult = logon; serviceResult = service; serviceBody = body; ignoreServices = ignore
    }
    func send(_ data: Data) throws {
        let packet = try CMPacket(data); sent.append(packet)
        var header = CMHeader(); header.steamID = testSteamID; header.sessionID = 123
        header.targetJob = packet.header.sourceJob
        switch packet.message {
        case EMsg.logOn.rawValue:
            var p = ProtoWriter(); p.uint(1, UInt64(logonResult)); p.uint(3, 1); p.uint(7, 42); p.string(21, "US")
            // Real logon replies need not carry a job target.
            header.targetJob = .max
            sink.yield(CMPacket(.logOnResponse, header: header, body: p.data).encoded())
        case EMsg.serviceCall.rawValue:
            if ignoreServices { return }
            header.result = serviceResult
            sink.yield(CMPacket(.serviceResponse, header: header, body: serviceBody).encoded())
        case EMsg.depotKey.rawValue:
            var p = ProtoWriter(); p.uint(1, 1); p.uint(2, 431960); p.bytes(3, testKey)
            sink.yield(CMPacket(.depotKeyResponse, header: header, body: p.data).encoded())
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

func directoryHTTP() -> SteamHTTP {
    SteamHTTP { request in
        response(request, Data(#"{"response":{"serverlist":[{"type":"websockets","endpoint":"cm1.invalid:443","wtd_load":1},{"type":"websockets","endpoint":"cm2.invalid:443","wtd_load":2}]}}"#.utf8))
    }
}

final class CMTests: XCTestCase {
    func testLogonJobsKeysHeartbeatAndHeaders() async throws {
        let fake = FakeCM(), client = SteamCMClient(machineName: "offline", http: directoryHTTP()) { _ in fake.connection }
        try await client.connect()
        let session = try await client.logOn(testTokens())
        XCTAssertEqual(session, SteamSession(steamID: testSteamID, cellID: 42, ipCountry: "US"))
        async let first = client.callService("One.Call#1", Data([1]))
        async let second = client.callService("Two.Call#1", Data([2]))
        _ = try await (first, second)
        let key = try await client.depotDecryptionKey(appID: 431960, depotID: 431960)
        XCTAssertTrue(key == testKey)
        _ = try await client.depotDecryptionKey(appID: 431960, depotID: 431960)
        try await Task.sleep(for: .milliseconds(1100))
        let packets = await fake.sent
        XCTAssertEqual(packets.filter { $0.message == EMsg.depotKey.rawValue }.count, 1)
        let service = packets.filter { $0.message == EMsg.serviceCall.rawValue }
        XCTAssertEqual(Set(service.map { $0.header.sourceJob }).count, 2)
        XCTAssertTrue(service.allSatisfy { $0.header.sessionID == 123 && $0.header.steamID == testSteamID })
        XCTAssertTrue(packets.contains { $0.message == EMsg.heartbeat.rawValue })
        await client.disconnect()
        let last = await fake.sent.last?.message
        XCTAssertEqual(last, EMsg.logOff.rawValue)
    }
    func testTimeoutCancellationAndDisconnectFailJobs() async throws {
        let fake = FakeCM()
        await fake.configure(ignore: true)
        let client = SteamCMClient(machineName: "offline", http: directoryHTTP(), jobTimeout: .milliseconds(30)) { _ in fake.connection }
        try await client.connect(); _ = try await client.logOn(testTokens())
        do { _ = try await client.callService("No.Reply#1", Data()); XCTFail("expected timeout") }
        catch { XCTAssertEqual(error as? SteamError, .timeout) }
        // A separate client with a long timeout: on a slow machine the 30 ms one could time out before the cancel or
        // the disconnect.
        let quiet = FakeCM()
        await quiet.configure(ignore: true)
        let patient = SteamCMClient(machineName: "offline", http: directoryHTTP(), jobTimeout: .seconds(30)) { _ in quiet.connection }
        try await patient.connect(); _ = try await patient.logOn(testTokens())
        let cancelled = Task { try await patient.callService("Cancel.Reply#1", Data()) }
        try await Task.sleep(for: .milliseconds(5)); cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let pending = Task { try await patient.callService("Disconnect.Reply#1", Data()) }
        try await Task.sleep(for: .milliseconds(5))
        quiet.sink.finish()
        do { _ = try await pending.value; XCTFail("expected disconnect") }
        catch { XCTAssertEqual(error as? SteamError, .disconnected) }
    }
    func testLogonServerRotationAndServiceError() async throws {
        let first = FakeCM(), second = FakeCM()
        await first.configure(logon: 48); await second.configure(service: 15)
        let client = SteamCMClient(machineName: "offline", http: directoryHTTP()) { url in
            url.host == "cm1.invalid" ? first.connection : second.connection
        }
        try await client.connect(); _ = try await client.logOn(testTokens())
        let attempts = await first.sent.count
        XCTAssertEqual(attempts, 1)
        do { _ = try await client.callService("Denied.Call#1", Data()); XCTFail("expected rejection") }
        catch { XCTAssertEqual(error as? SteamError, .result(15)) }
        await client.disconnect()
    }
    func testSubscriptionsOverCM() async throws {
        let fake = FakeCM()
        var item = ProtoWriter(); item.uint(2, 123)
        var response = ProtoWriter(); response.uint(1, 1); response.bytes(3, item.data)
        await fake.configure(body: response.data)
        let client = SteamCMClient(machineName: "offline", http: directoryHTTP()) { _ in fake.connection }
        try await client.connect(); _ = try await client.logOn(testTokens())
        let subs = try await SteamWorkshop(http: HTTPQueue([]).http).subscriptions(client: client, tokens: testTokens())
        XCTAssertEqual(subs.source, .cm); XCTAssertEqual(subs.ids, [123])
        let requests = await fake.sent
        let call = try XCTUnwrap(requests.first { $0.message == EMsg.serviceCall.rawValue })
        XCTAssertEqual(call.header.method, "PublishedFile.GetUserFiles#1")
        let fields = try ProtoReader(call.body)
        XCTAssertEqual(fields.uint(1), testSteamID); XCTAssertEqual(fields.uint(2), 431960)
        XCTAssertEqual(fields.uint(5), 100); XCTAssertEqual(fields.string(6), "mysubscriptions")
        XCTAssertEqual(fields.uint(18), 1)
        await client.disconnect()
    }
    func testLoggedOffEventAndWebSubscriptionFallback() async throws {
        let fake = FakeCM()
        await fake.configure(service: 8)
        let client = SteamCMClient(machineName: "offline", http: directoryHTTP()) { _ in fake.connection }
        try await client.connect(); _ = try await client.logOn(testTokens())
        let queue = HTTPQueue([
            (#"g_steamID = "76561198000000001"; sharedfiles/filedetails/?id=123 sharedfiles/filedetails/?id=123"#, 200, [:]),
            (#"g_steamID = "76561198000000001"; sharedfiles/filedetails/?id=123"#, 200, [:]),
        ])
        let subs = try await SteamWorkshop(http: queue.http).subscriptions(client: client, tokens: testTokens())
        XCTAssertEqual(subs.ids, [123]); XCTAssertEqual(subs.source, .web)
        let requests = await queue.requests
        XCTAssertTrue(requests[0].value(forHTTPHeaderField: "Cookie")?.contains("%7C%7C") == true)
        var loggedOff = ProtoWriter(); loggedOff.uint(1, 27)
        fake.sink.yield(CMPacket(.loggedOff, body: loggedOff.data).encoded())
        var events = client.events.makeAsyncIterator()
        let event = await events.next()
        XCTAssertEqual(event, .disconnected(.result(27)))
    }
}
