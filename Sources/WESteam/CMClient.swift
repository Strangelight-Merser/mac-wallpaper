import Foundation

/// CM session lifecycle diagnostics without sensitive payloads.
public enum SteamCMEvent: Sendable, Equatable {
    case ignoredMessage(UInt32), disconnected(SteamError)
}

struct CMConnection: Sendable {
    let send: @Sendable (Data) async throws -> Void
    let receive: @Sendable () async throws -> Data
    let close: @Sendable () -> Void
}

/// WebSocket-only CM connection with bounded jobs and session-scoped depot keys.
public actor SteamCMClient {
    public nonisolated let events: AsyncStream<SteamCMEvent>
    private let eventSink: AsyncStream<SteamCMEvent>.Continuation
    private let machineName: String
    private let http: SteamHTTP
    private let open: @Sendable (URL) async throws -> CMConnection
    private var connection: CMConnection?
    private var generation = UUID()
    private var receiver: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var endpoints: [URL] = []
    private var header = CMHeader()
    private var session: SteamSession?
    private var nextJob: UInt64 = 1
    private var logonJob: UInt64?
    private var connecting = false
    private var keys: [UInt32: Data] = [:]
    private var jobs: [UInt64: Job] = [:]
    private let jobTimeout: Duration
    private struct Job {
        let expected: EMsg
        let continuation: CheckedContinuation<CMPacket, Error>
        let timeout: Task<Void, Never>
    }

    public init(machineName: String) {
        self.machineName = machineName; http = SteamHTTP(); open = SocketOpener.open; jobTimeout = .seconds(15)
        (events, eventSink) = AsyncStream.makeStream()
    }
    init(machineName: String, http: SteamHTTP, jobTimeout: Duration = .seconds(15),
         open: @escaping @Sendable (URL) async throws -> CMConnection) {
        self.machineName = machineName; self.http = http; self.open = open; self.jobTimeout = jobTimeout
        (events, eventSink) = AsyncStream.makeStream()
    }
    deinit { receiver?.cancel(); heartbeat?.cancel(); connection?.close(); eventSink.finish() }

    public func connect() async throws {
        guard connection == nil, !connecting else { throw SteamError.malformed("CM already connected or connecting") }
        connecting = true
        defer { connecting = false }
        let attempt = UUID(); generation = attempt
        let response = try await http.api("ISteamDirectory", "GetCMListForConnect",
                                         fields: ["cellid": "0", "format": "json"], get: true)
        guard generation == attempt else { throw SteamError.disconnected }
        endpoints = response["serverlist"].array.filter { $0["type"].string == "websockets" }
            .sorted { $0["wtd_load"].double < $1["wtd_load"].double }.prefix(5).compactMap {
                URL(string: "wss://\($0["endpoint"].string)/cmsocket/")
            }
        try await connectNext()
    }
    private func connectNext() async throws {
        var last: Error = SteamError.malformed("no WebSocket CM servers")
        while !endpoints.isEmpty {
            try Task.checkCancellation()
            let url = endpoints.removeFirst()
            let id = UUID(); generation = id
            do {
                let socket = try await open(url)
                guard generation == id else { socket.close(); throw SteamError.disconnected }
                connection = socket
                receiver = Task { [weak self] in
                    do {
                        while !Task.isCancelled {
                            let data = try await socket.receive()
                            guard let self else { return }
                            try await self.receive(data, generation: id)
                        }
                    } catch { await self?.socketFailed(id) }
                }
                return
            } catch {
                guard generation == id else { throw SteamError.disconnected }
                if Task.isCancelled { throw CancellationError() }
                last = error
            }
        }
        throw last
    }
    public func logOn(_ tokens: SteamTokens) async throws -> SteamSession {
        guard connection != nil, session == nil, logonJob == nil else { throw SteamError.malformed("CM logon state") }
        let claims = try SteamJWT(tokens.refreshToken)
        guard claims.sub == String(tokens.steamID), claims.aud.contains("client"), claims.issuer == "steam",
              claims.exp > Date() else { throw SteamError.invalidToken }
        while true {
            header.steamID = tokens.steamID
            let attempt = generation
            let packet: CMPacket
            do {
                packet = try await request(.logOn, expected: .logOnResponse,
                                           body: CMLogon(tokens: tokens, machineName: machineName).encoded())
            } catch {
                if generation == attempt { end(.disconnected, notify: false) }
                throw error
            }
            guard generation == attempt, connection != nil else { throw SteamError.disconnected }
            let response = try CMLogonResponse(packet.body)
            if response.result != 1 {
                let retry = [20, 48].contains(response.result) // EResult.js: ServiceUnavailable, TryAnotherCM.
                end(.result(response.result), notify: false)
                if retry && !endpoints.isEmpty { try await connectNext(); continue }
                throw SteamError.result(response.result)
            }
            guard packet.header.steamID == tokens.steamID, packet.header.sessionID != 0,
                  response.heartbeat > 0, response.heartbeat <= 3600 else {
                end(.malformed("logon response"), notify: true)
                throw SteamError.malformed("logon response")
            }
            header.steamID = packet.header.steamID; header.sessionID = packet.header.sessionID
            let established = SteamSession(steamID: packet.header.steamID, cellID: response.cellID, ipCountry: response.country)
            session = established
            let id = generation, seconds = response.heartbeat
            heartbeat = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(seconds))
                        try await self?.sendHeartbeat(id)
                    }
                } catch { await self?.socketFailed(id) }
            }
            return established
        }
    }
    public func callService(_ method: String, _ body: Data) async throws -> Data {
        guard session != nil else { throw SteamError.disconnected }
        let response = try await request(.serviceCall, expected: .serviceResponse, body: body, method: method)
        guard response.header.result == 1 else { throw SteamError.result(response.header.result ?? 2) }
        return response.body
    }
    public func depotDecryptionKey(appID: UInt32, depotID: UInt32) async throws -> Data {
        guard session != nil else { throw SteamError.disconnected }
        if let key = keys[depotID] { return key }
        // steammessages_clientserver_2.proto: CMsgClientGetDepotDecryptionKey{,Response}.
        var p = ProtoWriter(); p.uint(1, UInt64(depotID)); p.uint(2, UInt64(appID))
        let attempt = generation
        let response = try await request(.depotKey, expected: .depotKeyResponse, body: p.data)
        guard generation == attempt, session != nil else { throw SteamError.disconnected }
        let result = try ProtoReader(response.body)
        guard result.uint(1, default: 2) == 1 else { throw SteamError.result(Int(result.uint(1, default: 2))) }
        guard result.uint(2) == depotID, result.bytes(3).count == 32 else { throw SteamError.malformed("depot key response") }
        keys[depotID] = result.bytes(3)
        return result.bytes(3)
    }
    public func disconnect() async {
        let socket = connection, packet = CMPacket(.logOff, header: header).encoded()
        end(.disconnected, notify: false, close: false)
        if let socket { try? await socket.send(packet); socket.close() }
    }
    private func request(_ message: EMsg, expected: EMsg, body: Data, method: String = "") async throws -> CMPacket {
        guard let socket = connection else { throw SteamError.disconnected }
        let job = nextJob; nextJob += 1
        var h = header; h.sourceJob = job; h.method = method
        let packet = CMPacket(message, header: h, body: body).encoded(), id = generation
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let timer = Task {
                    do { try await Task.sleep(for: jobTimeout) } catch { return }
                    finish(job, .failure(SteamError.timeout))
                }
                jobs[job] = Job(expected: expected, continuation: continuation, timeout: timer)
                if message == .logOn { logonJob = job }
                Task {
                    do { try await socket.send(packet) }
                    catch { socketFailed(id) }
                }
            }
        } onCancel: { Task { await self.cancel(job) } }
    }
    private func cancel(_ job: UInt64) { finish(job, .failure(CancellationError())) }
    private func finish(_ job: UInt64, _ result: Result<CMPacket, Error>) {
        guard let pending = jobs.removeValue(forKey: job) else { return }
        if logonJob == job { logonJob = nil }
        pending.timeout.cancel(); pending.continuation.resume(with: result)
    }
    private func receive(_ data: Data, generation id: UUID) throws {
        guard id == generation else { return }
        try process(CMPacket(data), depth: 0)
    }
    private func process(_ packet: CMPacket, depth: Int) throws {
        guard packet.protobuf else { eventSink.yield(.ignoredMessage(packet.message)); return }
        if packet.message == EMsg.multi.rawValue {
            guard depth < 16 else { throw SteamError.malformed("nested Multi limit") }
            for child in try packet.children() { try process(child, depth: depth + 1) }
            return
        }
        if packet.message == EMsg.loggedOff.rawValue {
            // steammessages_clientserver_login.proto: CMsgClientLoggedOff.eresult = 1.
            let result = try ProtoReader(packet.body).uint(1, default: 2)
            end(.result(Int(Int32(truncatingIfNeeded: result))), notify: true); return
        }
        let job = packet.message == EMsg.logOnResponse.rawValue ? (logonJob ?? .max) : packet.header.targetJob
        if let pending = jobs[job], pending.expected.rawValue == packet.message { finish(job, .success(packet)) }
    }
    private func sendHeartbeat(_ id: UUID) async throws {
        guard id == generation, let socket = connection else { return }
        // steammessages_clientserver_login.proto: CMsgClientHeartBeat.send_reply = 1.
        var p = ProtoWriter(); p.uint(1, 0)
        try await socket.send(CMPacket(.heartbeat, header: header, body: p.data).encoded())
    }
    private func socketFailed(_ id: UUID) {
        guard id == generation else { return }
        end(.disconnected, notify: true)
    }
    private func end(_ error: SteamError, notify: Bool, close: Bool = true) {
        generation = UUID()
        if close { connection?.close() }
        connection = nil; session = nil; header = CMHeader(); keys = [:]
        receiver?.cancel(); receiver = nil; heartbeat?.cancel(); heartbeat = nil
        for job in Array(jobs.keys) { finish(job, .failure(error)) }
        if notify { eventSink.yield(.disconnected(error)) }
    }
}

/// Delegate state is protected by the lock; completion, cancellation and timeout race through finish.
private final class SocketOpener: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished: Result<Void, Error>?
    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard finished == nil else { lock.unlock(); return }
        finished = result
        let c = continuation; continuation = nil
        lock.unlock(); c?.resume(with: result)
    }
    private func register(_ c: CheckedContinuation<Void, Error>) {
        lock.lock()
        let result = finished
        if result == nil { continuation = c }
        lock.unlock()
        if let result { c.resume(with: result) }
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        finish(.success(()))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(.failure(SteamError.disconnected))
    }
    static func open(_ url: URL) async throws -> CMConnection {
        let delegate = SocketOpener()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let socket = session.webSocketTask(with: url)
        // The default limit (1 MiB) is below what CMs send in Multi packets; Multi itself caps at 64 MiB.
        socket.maximumMessageSize = 64 * 1024 * 1024
        let timer = Task {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            delegate.finish(.failure(SteamError.timeout)); socket.cancel(with: .goingAway, reason: nil)
        }
        defer { timer.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { c in delegate.register(c); socket.resume() }
                try Task.checkCancellation()
            } onCancel: {
                delegate.finish(.failure(CancellationError())); socket.cancel(with: .goingAway, reason: nil)
            }
        } catch { session.invalidateAndCancel(); throw error }
        return CMConnection(send: { try await socket.send(.data($0)) }, receive: {
            let message = try await socket.receive()
            guard case .data(let data) = message else { throw SteamError.malformed("non-binary CM frame") }
            return data
        }, close: { socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() })
    }
}
