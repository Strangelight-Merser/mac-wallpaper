import Foundation
import Security

/// Persisted SteamClient credentials. Token values must never be logged.
public struct SteamTokens: Codable, Sendable, Equatable {
    public var accountName: String
    public var steamID: UInt64
    public var refreshToken: String
    public var accessToken: String?
    public init(accountName: String, steamID: UInt64, refreshToken: String, accessToken: String? = nil) {
        self.accountName = accountName; self.steamID = steamID
        self.refreshToken = refreshToken; self.accessToken = accessToken
    }
}

/// Unverified JWT claims for routing and expiration checks, not authentication.
public struct SteamJWT: Sendable, Equatable {
    public let sub: String
    public let aud: [String]
    public let exp: Date
    public let issuer: String
    public init(_ token: String) throws {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw SteamError.invalidToken }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              UInt64(json["sub"].string) != nil, json["exp"].double > 0 else { throw SteamError.invalidToken }
        sub = json["sub"].string
        aud = json["aud"].array.isEmpty ? [json["aud"].string].filter { !$0.isEmpty } : json["aud"].array.map(\.string)
        exp = Date(timeIntervalSince1970: json["exp"].double)
        issuer = json["iss"].string
    }
}

/// Generic-password Keychain storage, indexed by Steam account name.
public enum SteamKeychain {
    public static func save(_ tokens: SteamTokens) throws { try save(tokens, service: service) }
    public static func load(account: String? = nil) throws -> SteamTokens? { try load(account: account, service: service) }
    public static func delete(account: String) throws { try delete(account: account, service: service) }
    public static func accounts() throws -> [String] { try entries(service: service).compactMap { $0[kSecAttrAccount] as? String } }
    static let service = "dev.macwallpaper.steam"
    static func query(_ service: String, account: String? = nil) -> [CFString: Any] {
        var q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
        if let account { q[kSecAttrAccount] = account }
        return q
    }
    static func save(_ tokens: SteamTokens, service: String) throws {
        let q = query(service, account: tokens.accountName)
        let attributes: [CFString: Any] = [
            kSecValueData: try JSONEncoder().encode(tokens),
            kSecAttrGeneric: Data(String(Date().timeIntervalSince1970).utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(q.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SteamError.keychain(status) }
    }
    /// Attributes of the matching items, newest first. (The file-based macOS keychain rejects
    /// `kSecReturnData` together with `kSecMatchLimitAll` with errSecParam, so data is fetched per item.)
    static func entries(service: String, account: String? = nil) throws -> [[CFString: Any]] {
        var q = query(service, account: account)
        q[kSecMatchLimit] = kSecMatchLimitAll; q[kSecReturnAttributes] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[CFString: Any]] else { throw SteamError.keychain(status) }
        // Keychain modification dates can have only second precision.
        func savedAt(_ item: [CFString: Any]) -> Double {
            guard let data = item[kSecAttrGeneric] as? Data else { return 0 }
            return Double(String(decoding: data, as: UTF8.self)) ?? 0
        }
        return items.sorted { savedAt($0) > savedAt($1) }
    }
    static func load(account: String?, service: String) throws -> SteamTokens? {
        guard let first = try entries(service: service, account: account).first,
              let name = first[kSecAttrAccount] as? String else { return nil }
        var q = query(service, account: name)
        q[kSecMatchLimit] = kSecMatchLimitOne; q[kSecReturnData] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SteamError.keychain(status) }
        do { return try JSONDecoder().decode(SteamTokens.self, from: data) }
        catch { throw SteamError.malformed("stored credentials") }
    }
    static func delete(account: String, service: String) throws {
        let status = SecItemDelete(query(service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SteamError.keychain(status) }
    }
}
