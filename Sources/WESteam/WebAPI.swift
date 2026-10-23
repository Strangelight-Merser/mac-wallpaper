import Foundation

enum JSONValue: Decodable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), integer(UInt64), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(UInt64.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    subscript(_ key: String) -> JSONValue { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    var string: String {
        switch self {
        case .string(let s): return s
        case .integer(let n): return String(n)
        case .number(let n): return String(n)
        default: return ""
        }
    }
    var uint: UInt64 { UInt64(string) ?? 0 }
    var double: Double { Double(string) ?? 0 }
    var bool: Bool { if case .bool(let b) = self { return b }; return uint != 0 }
    var array: [JSONValue] { if case .array(let v) = self { return v }; return [] }
    var isNull: Bool { if case .null = self { return true }; return false }
}

/// HTTPS transport with form encoding and redacted errors. The injected loader supports offline tests.
struct SteamHTTP: Sendable {
    typealias Loader = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    let load: Loader
    private let boundedLoad: (@Sendable (URLRequest, Int) async throws -> (Data, HTTPURLResponse))?
    init(load: Loader? = nil) {
        self.load = load ?? SteamHTTP.systemLoad
        boundedLoad = load == nil ? SteamHTTP.systemBoundedLoad : nil
    }
    static func systemBoundedLoad(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw SteamError.transport }
            guard (200..<300).contains(http.statusCode) else { throw SteamError.http(http.statusCode) }
            if response.expectedContentLength > limit { throw SteamError.tooLarge(response.expectedContentLength) }
            var data = Data()
            for try await byte in bytes {
                guard data.count < limit else { throw SteamError.tooLarge(Int64(data.count) + 1) }
                data.append(byte)
            }
            return (data, http)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let error = error as? SteamError { throw error }
            throw SteamError.transport
        }
    }
    static func systemLoad(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SteamError.transport }
            return (data, http)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw SteamError.transport
        }
    }
    static func form(_ fields: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return fields.sorted { $0.key < $1.key }.map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" +
            $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&")
    }
    func api(_ service: String, _ method: String, fields: [String: String] = [:], get: Bool = false, protobufResponse: String? = nil) async throws -> JSONValue {
        var components = URLComponents(string: "https://api.steampowered.com/\(service)/\(method)/v1/")!
        if get { components.percentEncodedQuery = Self.form(fields) }
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.httpMethod = get ? "GET" : "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !get { request.httpBody = Data(Self.form(fields).utf8) }
        let (data, response) = try await load(request)
        if let raw = response.value(forHTTPHeaderField: "x-eresult"), let result = Int(raw), result != 1 {
            throw SteamError.result(result)
        }
        guard (200..<300).contains(response.statusCode) else { throw SteamError.http(response.statusCode) }
        if let value = try? JSONDecoder().decode(JSONValue.self, from: data), !value["response"].isNull {
            return value["response"]
        }
        // steam-session/dist/AuthenticationClient.js decodes binary responses on the protobuf transport.
        if let protobufResponse { return try authResponse(protobufResponse, data: data) }
        throw SteamError.malformed("WebAPI response")
    }
    func auth(_ method: String, fields: [String: String], protobuf: Data, get: Bool = false) async throws -> JSONValue {
        do { return try await api("IAuthenticationService", method, fields: fields, get: get, protobufResponse: method) }
        catch let error as SteamError {
            // EResult.InvalidParam (8): enums/EResult.js. Retry only input-format rejection.
            guard error == .result(8) || error == .http(400) || error == .http(415) else { throw error }
            return try await api("IAuthenticationService", method,
                                 fields: ["input_protobuf_encoded": protobuf.base64EncodedString()], get: get, protobufResponse: method)
        }
    }
    func get(_ url: URL, headers: [String: String] = [:], limit: Int? = nil) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.allHTTPHeaderFields = headers
        let data: Data, response: HTTPURLResponse
        if let limit, let boundedLoad { (data, response) = try await boundedLoad(request, limit) }
        else { (data, response) = try await load(request) }
        guard (200..<300).contains(response.statusCode) else { throw SteamError.http(response.statusCode) }
        if let limit, data.count > limit { throw SteamError.tooLarge(Int64(data.count)) }
        return data
    }
}


// steammessages_auth.steamclient.proto: response field numbers and scalar wire types.
private func authResponse(_ method: String, data: Data) throws -> JSONValue {
    let p = try ProtoReader(data)
    func confirmations(_ field: Int) throws -> JSONValue {
        .array(try p.repeated(field).map {
            let c = try ProtoReader($0)
            return .object(["confirmation_type": .integer(c.uint(1)), "associated_message": .string(c.string(2))])
        })
    }
    switch method {
    case "GetPasswordRSAPublicKey":
        return .object(["publickey_mod": .string(p.string(1)), "publickey_exp": .string(p.string(2)), "timestamp": .integer(p.uint(3))])
    case "BeginAuthSessionViaQR":
        return .object(["client_id": .integer(p.uint(1)), "challenge_url": .string(p.string(2)),
                        "request_id": .string(p.bytes(3).base64EncodedString()),
                        "interval": .number(Double(Float(bitPattern: UInt32(truncatingIfNeeded: p.uint(4))))),
                        "allowed_confirmations": try confirmations(5)])
    case "BeginAuthSessionViaCredentials":
        return .object(["client_id": .integer(p.uint(1)), "request_id": .string(p.bytes(2).base64EncodedString()),
                        "interval": .number(Double(Float(bitPattern: UInt32(truncatingIfNeeded: p.uint(3))))),
                        "allowed_confirmations": try confirmations(4), "steamid": .integer(p.uint(5))])
    case "PollAuthSessionStatus":
        return .object(["new_client_id": .integer(p.uint(1)), "new_challenge_url": .string(p.string(2)),
                        "refresh_token": .string(p.string(3)), "access_token": .string(p.string(4)),
                        "had_remote_interaction": .bool(p.uint(5) != 0), "account_name": .string(p.string(6))])
    case "GenerateAccessTokenForApp":
        return .object(["access_token": .string(p.string(1)), "refresh_token": .string(p.string(2))])
    case "UpdateAuthSessionWithSteamGuardCode": return .object([:])
    default: throw SteamError.malformed("unknown authentication response")
    }
}
