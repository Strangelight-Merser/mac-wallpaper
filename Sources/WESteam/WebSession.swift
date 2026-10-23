import Foundation

/// Cookies for Steam community/store. An absent access token produces no cookies.
public func webCookies(_ tokens: SteamTokens) -> [HTTPCookie] {
    guard let access = tokens.accessToken, !access.isEmpty else { return [] }
    let session = (0..<12).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    return ["steamcommunity.com", "store.steampowered.com"].flatMap { domain in
        let base: [HTTPCookiePropertyKey: Any] = [.domain: domain, .path: "/", .secure: "TRUE"]
        let login = base.merging([
            .name: "steamLoginSecure", .value: "\(tokens.steamID)%7C%7C\(access)",
            HTTPCookiePropertyKey("HttpOnly"): "TRUE",
        ]) { _, value in value }
        let csrf = base.merging([.name: "sessionid", .value: session]) { _, value in value }
        return [HTTPCookie(properties: login), HTTPCookie(properties: csrf)].compactMap { $0 }
    }
}
