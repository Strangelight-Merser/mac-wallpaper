import Foundation
import WEFormat

// steammessages_clientserver_appinfo.proto: CMsgClientPICS{AccessToken,ProductInfo}{Request,Response}.
enum PICS {
    static func accessTokenRequest(_ appID: UInt32) -> Data {
        var p = ProtoWriter(); p.uint(2, UInt64(appID)); return p.data
    }
    static func accessToken(_ data: Data, appID: UInt32) throws -> UInt64 {
        let p = try ProtoReader(data)
        for field in p.fields where field.number == 4 {
            if field.wire == 0, field.value == appID { throw SteamError.malformed("PICS app access token denied") }
            if field.wire == 2 {
                var packed = ByteCursor(field.data)
                while packed.remaining > 0 {
                    if try packed.varint() == appID { throw SteamError.malformed("PICS app access token denied") }
                }
            }
        }
        for bytes in p.repeated(3) {
            let token = try ProtoReader(bytes)
            if token.uint(1) == appID { return token.uint(2) }
        }
        // Public app information may not require a token (apps.js, getProductAccessToken).
        return 0
    }
    static func productInfoRequest(_ appID: UInt32, token: UInt64) -> Data {
        var app = ProtoWriter(); app.uint(1, UInt64(appID)); app.uint(2, token)
        var p = ProtoWriter(); p.bytes(2, app.data); return p.data
    }
    static func appInfo(_ data: Data, appID: UInt32) throws -> VDF.Value {
        for bytes in try ProtoReader(data).repeated(1) {
            let app = try ProtoReader(bytes)
            guard app.uint(1) == appID else { continue }
            guard app.uint(3) == 0 else { throw SteamError.malformed("PICS app information requires an access token") }
            var buffer = app.bytes(5)
            if buffer.last == 0 { buffer.removeLast() }
            guard let text = String(data: buffer, encoding: .utf8), !text.isEmpty,
                  let info = try VDF.parse(text)["appinfo"] else { throw SteamError.malformed("PICS app information missing text VDF") }
            return info
        }
        throw SteamError.malformed("PICS app information unavailable for app \(appID)")
    }
}

struct AssetsAppInfo: Sendable {
    let buildID: UInt64
    let depots: [WEAssetsDepot]

    init(_ info: VDF.Value) throws {
        guard let depots = info["depots"],
              let build = depots["branches"]?["public"]?["buildid"]?.string.flatMap(UInt64.init) else {
            throw SteamError.malformed("Wallpaper Engine has no public branch build ID")
        }
        buildID = build
        self.depots = depots.pairs.compactMap { pair in
            guard let id = UInt32(pair.key), id > 0 else { return nil }
            let depot = pair.value
            for key in ["sharedinstall", "depotfromapp", "dlcappid"] {
                if let value = depot[key]?.string, !value.isEmpty, value != "0" { return nil }
            }
            if let oslist = depot["config"]?["oslist"]?.string {
                let systems = oslist.lowercased().split { $0 == "," || $0.isWhitespace }
                guard systems.contains("windows") else { return nil }
            }
            guard let branch = depot["manifests"]?["public"],
                  let gid = (branch["gid"]?.string ?? branch.string).flatMap(UInt64.init), gid > 0 else { return nil }
            return WEAssetsDepot(depotID: id, manifestID: gid)
        }.sorted { $0.depotID < $1.depotID }
        guard !self.depots.isEmpty else { throw SteamError.malformed("Wallpaper Engine has no eligible Windows depot with a public manifest") }
    }
}
