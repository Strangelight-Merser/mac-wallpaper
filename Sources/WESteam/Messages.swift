import Foundation

// steam-user/enums/EMsg.js.
enum EMsg: UInt32 {
    case multi = 1, serviceResponse = 147, serviceCall = 151
    case heartbeat = 703, logOff = 706, logOnResponse = 751, loggedOff = 757
    case depotKey = 5438, depotKeyResponse = 5439, logOn = 5514
}

// steammessages_base.proto, CMsgProtoBufHeader.
struct CMHeader: Sendable, Equatable {
    var steamID: UInt64 = 0
    var sessionID: Int32 = 0
    var sourceJob: UInt64 = .max
    var targetJob: UInt64 = .max
    var method = ""
    var result: Int?
    var errorMessage = ""
    var realm: UInt32 = 0
    init() {}
    init(_ data: Data) throws {
        let p = try ProtoReader(data)
        steamID = p.uint(1); sessionID = Int32(truncatingIfNeeded: p.uint(2))
        sourceJob = p.uint(10, default: .max); targetJob = p.uint(11, default: .max)
        method = p.string(12); result = p.contains(13) ? Int(Int32(truncatingIfNeeded: p.uint(13))) : nil
        errorMessage = p.string(14); realm = UInt32(truncatingIfNeeded: p.uint(32))
    }
    func encoded() -> Data {
        var p = ProtoWriter()
        p.fixed64(1, steamID); p.uint(2, UInt64(bitPattern: Int64(sessionID)))
        p.fixed64(10, sourceJob); p.fixed64(11, targetJob)
        if !method.isEmpty { p.string(12, method) }
        if let result { p.uint(13, UInt64(bitPattern: Int64(result))) }
        if !errorMessage.isEmpty { p.string(14, errorMessage) }
        if realm != 0 { p.uint(32, UInt64(realm)) }
        return p.data
    }
}

struct CMPacket: Sendable {
    var message: UInt32
    var header: CMHeader
    var body: Data
    var protobuf = true
    init(_ message: EMsg, header: CMHeader = CMHeader(), body: Data = Data()) {
        self.message = message.rawValue; self.header = header; self.body = body
    }
    init(_ data: Data) throws {
        var cursor = ByteCursor(data)
        // steam-user/components/03-messages.js: PROTO_MASK and packet framing.
        let raw = try cursor.integer(UInt32.self)
        message = raw & 0x7fffffff; protobuf = raw & 0x80000000 != 0
        if protobuf {
            let length = try cursor.integer(UInt32.self)
            header = try CMHeader(cursor.read(Int(length)))
        } else { header = CMHeader() }
        body = try cursor.read(cursor.remaining)
    }
    func encoded() -> Data {
        let header = header.encoded()
        var data = Data(); data.appendLE(message | 0x80000000); data.appendLE(UInt32(header.count))
        data.append(header); data.append(body); return data
    }
    func children() throws -> [CMPacket] {
        // steammessages_base.proto: CMsgMulti; 03-messages.js: _processMulti.
        let p = try ProtoReader(body), size = p.uint(1)
        guard size <= 64 * 1024 * 1024 else { throw SteamError.malformed("Multi size limit") }
        let bytes = size == 0 ? p.bytes(2) : try ChunkCodec.inflate(p.bytes(2), size: Int(size), windowBits: 31)
        var cursor = ByteCursor(bytes), result: [CMPacket] = []
        while cursor.remaining > 0 {
            let size = try cursor.integer(UInt32.self)
            result.append(try CMPacket(cursor.read(Int(size))))
        }
        return result
    }
}

// steammessages_clientserver_login.proto, CMsgClientLogon.
struct CMLogon: Sendable, Equatable {
    var token: String
    var machineName: String
    var machine: Data
    init(tokens: SteamTokens, machineName: String) {
        token = tokens.refreshToken; self.machineName = machineName; machine = machineID(tokens.accountName)
    }
    init(_ data: Data) throws {
        let p = try ProtoReader(data)
        token = p.string(108); machineName = p.string(96); machine = p.bytes(30)
    }
    func encoded() -> Data {
        var p = ProtoWriter()
        p.uint(1, 65580) // steam-user/components/09-logon.js: PROTOCOL_VERSION.
        p.string(6, "english")
        p.uint(7, UInt64(UInt32(bitPattern: -102))) // EOSType.js: MacOSUnknown, uint32 on the wire.
        p.uint(8, 1)
        var ip = ProtoWriter(); ip.fixed32(1, 0) // steammessages_base.proto: CMsgIPAddress.v4.
        p.bytes(11, ip.data); p.bytes(30, machine); p.string(96, machineName); p.uint(102, 1)
        p.string(108, token)
        // 09-logon.js forbids account_name with refreshToken, contrary to spec §7.2's field list.
        return p.data
    }
}

struct CMLogonResponse: Sendable {
    let result: Int
    let heartbeat: UInt64
    let cellID: UInt32
    let country: String
    let publicIP: Data
    let suppliedSteamID: UInt64
    init(_ data: Data) throws {
        // steammessages_clientserver_login.proto, CMsgClientLogonResponse.
        let p = try ProtoReader(data)
        result = Int(Int32(truncatingIfNeeded: p.uint(1, default: 2)))
        heartbeat = p.uint(3); cellID = UInt32(truncatingIfNeeded: p.uint(7))
        publicIP = p.bytes(15); suppliedSteamID = p.uint(20); country = p.string(21)
    }
}

/// The authenticated CM identity and content-server routing hints.
public struct SteamSession: Sendable, Equatable {
    public let steamID: UInt64
    public let cellID: UInt32
    public let ipCountry: String
    public init(steamID: UInt64, cellID: UInt32, ipCountry: String) {
        self.steamID = steamID; self.cellID = cellID; self.ipCountry = ipCountry
    }
}
