import Foundation
import Security

/// QR challenge updates and successful authentication.
public enum QRLoginEvent: Sendable {
    case challenge(URL), scanned, succeeded(SteamTokens)
}

/// Steam Guard alternatives offered by a credential login.
public struct SteamGuardConfirmation: Sendable, Equatable {
    /// Values from steammessages_auth.steamclient.proto, EAuthSessionGuardType.
    public enum Kind: Int, Sendable { case none = 1, emailCode = 2, deviceCode = 3, deviceConfirmation = 4, emailConfirmation = 5 }
    public let kind: Kind
    public let message: String
}

/// Starts a QR login and polls until approval, cancellation or ten-minute expiry.
public struct SteamQRLogin: Sendable {
    let deviceName: String
    let http: SteamHTTP
    public init(deviceName: String) { self.deviceName = deviceName; http = SteamHTTP() }
    init(deviceName: String, http: SteamHTTP) { self.deviceName = deviceName; self.http = http }
    public func events() -> AsyncThrowingStream<QRLoginEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // steammessages_auth.steamclient.proto: BeginAuthSessionViaQR_Request.
                    var p = ProtoWriter(); p.string(1, deviceName); p.uint(2, 1); p.bytes(3, deviceDetails(deviceName))
                    let response = try await http.auth("BeginAuthSessionViaQR",
                        fields: ["device_friendly_name": deviceName, "platform_type": "1"], protobuf: p.data)
                    let session = try AuthSession(response)
                    guard let url = URL(string: response["challenge_url"].string), url.scheme == "https" else {
                        throw SteamError.malformed("QR challenge")
                    }
                    continuation.yield(.challenge(url))
                    let tokens = try await poll(session, http: http) { continuation.yield($0) }
                    continuation.yield(.succeeded(tokens)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Credential login with a caller-selected Steam Guard alternative.
public struct SteamPasswordLogin: Sendable {
    let deviceName: String
    let http: SteamHTTP
    public init(deviceName: String) { self.deviceName = deviceName; http = SteamHTTP() }
    init(deviceName: String, http: SteamHTTP) { self.deviceName = deviceName; self.http = http }
    /// The callback chooses an offered confirmation; return a code only for email/device code.
    public func login(account: String, password: String,
                      guardResponse: @Sendable ([SteamGuardConfirmation]) async throws -> (SteamGuardConfirmation.Kind, String?)) async throws -> SteamTokens {
        // Field numbers throughout this file: steammessages_auth.steamclient.proto.
        var keyRequest = ProtoWriter(); keyRequest.string(1, account)
        let key = try await http.auth("GetPasswordRSAPublicKey", fields: ["account_name": account], protobuf: keyRequest.data, get: true)
        let encrypted = try encryptPassword(password, modulus: key["publickey_mod"].string, exponent: key["publickey_exp"].string)
        let device = deviceDetails(deviceName, account: account)
        var p = ProtoWriter()
        p.string(1, deviceName); p.string(2, account); p.string(3, encrypted); p.uint(4, key["timestamp"].uint)
        p.uint(5, 1); p.uint(6, 1); p.uint(7, 1); p.string(8, "Unknown"); p.bytes(9, device)
        // Persistent = 1 in enums.proto, SteamClient = 1 in steammessages_auth.steamclient.proto.
        let details: [String: Any] = ["device_friendly_name": deviceName, "platform_type": 1, "os_type": -102,
                                      "gaming_device_type": 1, "machine_id": machineID(account).base64EncodedString()]
        let deviceJSON = String(decoding: try JSONSerialization.data(withJSONObject: details), as: UTF8.self)
        let response = try await http.auth("BeginAuthSessionViaCredentials", fields: [
            "device_friendly_name": deviceName, "account_name": account, "encrypted_password": encrypted,
            "encryption_timestamp": key["timestamp"].string, "remember_login": "true", "platform_type": "1",
            "persistence": "1", "website_id": "Unknown", "device_details": deviceJSON,
        ], protobuf: p.data)
        let session = try AuthSession(response)
        let confirmations = response["allowed_confirmations"].array.compactMap { value -> SteamGuardConfirmation? in
            guard let kind = SteamGuardConfirmation.Kind(rawValue: Int(value["confirmation_type"].uint)) else { return nil }
            return SteamGuardConfirmation(kind: kind, message: value["associated_message"].string)
        }
        guard !confirmations.isEmpty else { throw SteamError.malformed("unsupported Steam Guard confirmation") }
        if !confirmations.contains(where: { $0.kind == .none }) {
            let (kind, code) = try await guardResponse(confirmations)
            guard confirmations.contains(where: { $0.kind == kind }) else { throw SteamError.malformed("Steam Guard selection") }
            if kind == .emailCode || kind == .deviceCode {
                guard let code, !code.isEmpty else { throw SteamError.malformed("Steam Guard code required") }
                var update = ProtoWriter()
                update.uint(1, session.clientID); update.fixed64(2, response["steamid"].uint)
                update.string(3, code); update.uint(4, UInt64(kind.rawValue))
                _ = try await http.auth("UpdateAuthSessionWithSteamGuardCode", fields: [
                    "client_id": String(session.clientID), "steamid": response["steamid"].string,
                    "code": code, "code_type": String(kind.rawValue),
                ], protobuf: update.data)
            }
        }
        return try await poll(session, http: http) { _ in }
    }
}

/// Renews access tokens with less than one hour remaining; callers persist the returned tokens.
public func freshAccessToken(_ tokens: SteamTokens) async throws -> SteamTokens {
    try await renew(tokens, http: SteamHTTP())
}

func renew(_ tokens: SteamTokens, http: SteamHTTP, now: Date = Date()) async throws -> SteamTokens {
    if let access = tokens.accessToken, let claims = try? SteamJWT(access),
       claims.sub == String(tokens.steamID), claims.exp.timeIntervalSince(now) >= 3600 { return tokens }
    var p = ProtoWriter(); p.string(1, tokens.refreshToken); p.fixed64(2, tokens.steamID); p.uint(3, 1)
    let result = try await http.auth("GenerateAccessTokenForApp", fields: [
        "refresh_token": tokens.refreshToken, "steamid": String(tokens.steamID), "renewal_type": "1",
    ], protobuf: p.data)
    guard !result["access_token"].string.isEmpty else { throw SteamError.malformed("access token response") }
    var updated = tokens; updated.accessToken = result["access_token"].string
    if !result["refresh_token"].string.isEmpty { updated.refreshToken = result["refresh_token"].string }
    return updated
}

struct AuthSession: Sendable {
    var clientID: UInt64
    let requestID: Data
    let interval: Double
    let started = ContinuousClock.now
    init(_ json: JSONValue) throws {
        guard json["client_id"].uint != 0, let request = Data(base64Encoded: json["request_id"].string),
              !request.isEmpty, json["interval"].double > 0, json["interval"].double.isFinite else {
            throw SteamError.malformed("authentication session")
        }
        clientID = json["client_id"].uint; requestID = request; interval = json["interval"].double
    }
}

func poll(_ initial: AuthSession, http: SteamHTTP, timeout: Duration = .seconds(600),
          event: @Sendable (QRLoginEvent) -> Void) async throws -> SteamTokens {
    let session = initial
    var scanned = false
    let deadline = session.started.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        try Task.checkCancellation()
        try await Task.sleep(for: min(.seconds(session.interval), ContinuousClock.now.duration(to: deadline)))
        guard ContinuousClock.now < deadline else { throw SteamError.expired }
        var p = ProtoWriter(); p.uint(1, session.clientID); p.bytes(2, session.requestID)
        let response = try await http.auth("PollAuthSessionStatus", fields: [
            "client_id": String(session.clientID), "request_id": session.requestID.base64EncodedString(),
        ], protobuf: p.data)
        guard ContinuousClock.now < deadline else { throw SteamError.expired }
        // Keep polling with the original client_id: switching to `new_client_id` (as steam-session does) ended
        // scanned QR sessions with EResult 9 (FileNotFound) in live tests; the original ID led to approval.
        if let url = URL(string: response["new_challenge_url"].string), url.scheme == "https" { event(.challenge(url)) }
        if response["had_remote_interaction"].bool && !scanned { scanned = true; event(.scanned) }
        let refresh = response["refresh_token"].string
        if !refresh.isEmpty {
            let claims = try SteamJWT(refresh)
            guard let id = UInt64(claims.sub), claims.aud.contains("client") else { throw SteamError.invalidToken }
            let access = response["access_token"].string
            return SteamTokens(accountName: response["account_name"].string, steamID: id, refreshToken: refresh,
                               accessToken: access.isEmpty ? nil : access)
        }
    }
    throw SteamError.expired
}

func deviceDetails(_ name: String, account: String? = nil) -> Data {
    var p = ProtoWriter(); p.string(1, name); p.uint(2, 1)
    // EOSType.MacOSUnknown = -102 in steam-user/enums/EOSType.js; desktop = 1 in AuthenticationClient.js.
    p.uint(3, UInt64(bitPattern: -102)); p.uint(4, 1)
    if let account { p.bytes(6, machineID(account)) }
    return p.data
}

func machineID(_ account: String) -> Data {
    // steam-session/dist/helpers.js, createMachineId: binary KeyValues MessageObject.
    var data = Data([0]); data.append(Data("MessageObject\0".utf8))
    for key in ["BB3", "FF2", "3B3"] {
        data.append(1); data.append(Data((key + "\0").utf8))
        data.append(Data((ChunkCodec.sha1(Data("SteamUser Hash \(key) \(account)".utf8)).hex + "\0").utf8))
    }
    data.append(contentsOf: [8, 8]); return data
}

func encryptPassword(_ password: String, modulus: String, exponent: String) throws -> String {
    func integer(_ hex: String) throws -> Data {
        var hex = hex
        if hex.count % 2 != 0 { hex = "0" + hex }
        var bytes = Data()
        while !hex.isEmpty {
            guard let byte = UInt8(hex.prefix(2), radix: 16) else { throw SteamError.malformed("RSA key") }
            bytes.append(byte); hex.removeFirst(2)
        }
        while bytes.count > 1 && bytes.first == 0 { bytes.removeFirst() }
        guard let first = bytes.first else { throw SteamError.malformed("RSA key") }
        if first & 128 != 0 { bytes.insert(0, at: bytes.startIndex) }
        return der(2, bytes)
    }
    let encoded = try der(0x30, integer(modulus) + integer(exponent))
    let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
    guard let key = SecKeyCreateWithData(encoded as CFData, attributes as CFDictionary, nil),
          let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, Data(password.utf8) as CFData, nil) else {
        throw SteamError.malformed("RSA password encryption")
    }
    return (encrypted as Data).base64EncodedString()
}

func der(_ tag: UInt8, _ data: Data) -> Data {
    var out = Data([tag])
    if data.count < 128 { out.append(UInt8(data.count)) }
    else {
        var n = data.count, length = [UInt8]()
        while n > 0 { length.insert(UInt8(n & 255), at: 0); n >>= 8 }
        out.append(0x80 | UInt8(length.count)); out.append(contentsOf: length)
    }
    out.append(data); return out
}
