import Foundation

/// Public workshop metadata; unavailable items retain their per-item EResult.
public struct WorkshopItem: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable { case scene = "Scene", video = "Video", web = "Web", application = "Application", preset = "Preset" }
    public enum Rating: String, Sendable, Codable { case everyone = "Everyone", questionable = "Questionable", mature = "Mature" }
    public var id: UInt64
    public var appID: UInt32
    public var title: String
    public var fileSize: Int64
    public var timeUpdated: Date
    public var contentManifestID: UInt64
    public var previewURL: URL?
    public var tags: [String]
    public var kind: Kind?
    public var rating: Rating?
    public var result: Int
    public var creatorID: UInt64?
    public var shortDescription: String?
    public var subscriptions: UInt64?
    public var favorites: UInt64?
    public var voteScore: Double?
    public var votesUp: UInt64?
    public var votesDown: UInt64?
    public var timeCreated: Date?
    public var metadata: String?

    /// Steam UGC resizing parameters; preserves unrelated URL parameters.
    public func previewURL(width: Int = 320, height: Int = 180) -> URL? {
        guard width > 0, height > 0, let previewURL,
              var url = URLComponents(url: previewURL, resolvingAgainstBaseURL: false) else { return nil }
        // Steam's image CDN ignores imw/imh unless impolicy=Letterbox; letterbox=false keeps the aspect ratio
        // without padding. Animated GIFs are never resized (see WorkshopImage, which reads only their first frame).
        let names = ["imw", "imh", "ima", "impolicy", "imcolor", "letterbox"]
        var query = (url.queryItems ?? []).filter { !names.contains($0.name) }
        query += [URLQueryItem(name: "imw", value: String(width)), URLQueryItem(name: "imh", value: String(height)),
                  URLQueryItem(name: "ima", value: "fit"), URLQueryItem(name: "impolicy", value: "Letterbox"),
                  URLQueryItem(name: "imcolor", value: "#000000"), URLQueryItem(name: "letterbox", value: "false")]
        url.queryItems = query
        return url.url
    }
    public init(id: UInt64, appID: UInt32, title: String, fileSize: Int64, timeUpdated: Date,
                contentManifestID: UInt64, previewURL: URL? = nil, tags: [String] = [], result: Int = 1) {
        self.id = id; self.appID = appID; self.title = title; self.fileSize = fileSize
        self.timeUpdated = timeUpdated; self.contentManifestID = contentManifestID
        self.previewURL = previewURL; self.tags = tags; self.result = result
        kind = tags.compactMap(Kind.init(rawValue:)).first; rating = tags.compactMap(Rating.init(rawValue:)).first
    }
}

/// Subscription IDs and the source used to retrieve them.
public struct SteamSubscriptions: Sendable, Codable, Equatable {
    public enum Source: String, Sendable, Codable { case cm, web }
    public let ids: [UInt64]
    public let source: Source
}

/// Public item lookup and authenticated workshop subscriptions.
public struct SteamWorkshop: Sendable {
    let http: SteamHTTP
    public init() { http = SteamHTTP() }
    init(http: SteamHTTP) { self.http = http }
    public func details(_ ids: [UInt64]) async throws -> [WorkshopItem] {
        var items: [WorkshopItem] = []
        for start in stride(from: 0, to: ids.count, by: 100) {
            let batch = Array(ids[start..<min(start + 100, ids.count)])
            var fields = ["itemcount": String(batch.count)]
            for (i, id) in batch.enumerated() { fields["publishedfileids[\(i)]"] = String(id) }
            let response = try await http.api("ISteamRemoteStorage", "GetPublishedFileDetails", fields: fields)
            for value in response["publishedfiledetails"].array {
                guard value["publishedfileid"].uint > 0, value["file_size"].uint <= Int64.max,
                      value["consumer_app_id"].uint <= UInt32.max else { throw SteamError.malformed("workshop details") }
                items.append(WorkshopItem(id: value["publishedfileid"].uint, appID: UInt32(value["consumer_app_id"].uint),
                    title: value["title"].string, fileSize: Int64(value["file_size"].uint),
                    timeUpdated: Date(timeIntervalSince1970: value["time_updated"].double),
                    contentManifestID: value["hcontent_file"].uint, previewURL: URL(string: value["preview_url"].string),
                    tags: value["tags"].array.map { $0["tag"].string }, result: Int(value["result"].uint)))
            }
        }
        return items
    }
    /// Tries the CM service first; only a Steam service rejection activates the authenticated web fallback.
    public func subscriptions(client: SteamCMClient, tokens: SteamTokens) async throws -> SteamSubscriptions {
        do {
            var ids: [UInt64] = [], seen = Set<UInt64>(), page: UInt64 = 1
            while true {
                // steammessages_publishedfile.steamclient.proto: GetUserFiles and PublishedFileDetails.
                var p = ProtoWriter(); p.fixed64(1, tokens.steamID); p.uint(2, 431960)
                p.uint(4, page); p.uint(5, 100); p.string(6, "mysubscriptions"); p.uint(18, 1)
                let response = try ProtoReader(await client.callService("PublishedFile.GetUserFiles#1", p.data))
                let batch = try response.repeated(3).map { try ProtoReader($0).uint(2) }.filter { $0 != 0 }
                let fresh = batch.filter { seen.insert($0).inserted }; ids += fresh
                if UInt64(ids.count) >= response.uint(1) { return SteamSubscriptions(ids: ids, source: .cm) }
                guard !fresh.isEmpty else { throw SteamError.malformed("subscription pagination stalled") }
                page += 1
            }
        } catch let error as SteamError {
            guard case .result = error else { throw error }
            return try await webSubscriptions(tokens)
        }
    }
    func webSubscriptions(_ tokens: SteamTokens) async throws -> SteamSubscriptions {
        let cookies = webCookies(tokens).filter { $0.domain == "steamcommunity.com" || $0.domain == ".steamcommunity.com" }
        guard !cookies.isEmpty else { throw SteamError.invalidToken }
        let headers = HTTPCookie.requestHeaderFields(with: cookies)
        var ids: [UInt64] = [], seen = Set<UInt64>(), page = 1
        while true {
            let url = URL(string: "https://steamcommunity.com/profiles/\(tokens.steamID)/myworkshopfiles/?appid=431960&browsefilter=mysubscriptions&p=\(page)&numperpage=30")!
            let html = String(decoding: try await http.get(url, headers: headers), as: UTF8.self)
            let batch = try Self.subscriptionPage(html, steamID: tokens.steamID)
            let fresh = batch.filter { seen.insert($0).inserted }
            if fresh.isEmpty { return SteamSubscriptions(ids: ids, source: .web) }
            ids += fresh; page += 1
        }
    }
    static func subscriptionPage(_ html: String, steamID: UInt64) throws -> [UInt64] {
        let login = try NSRegularExpression(pattern: #"g_steamID\s*=\s*["']"# + String(steamID) + #"["']"#)
        let range = NSRange(html.startIndex..., in: html)
        guard login.firstMatch(in: html, range: range) != nil else { throw SteamError.invalidToken }
        let regex = try NSRegularExpression(pattern: #"sharedfiles/filedetails/\?id=(\d+)"#)
        return regex.matches(in: html, range: range).compactMap {
            Range($0.range(at: 1), in: html).flatMap { UInt64(html[$0]) }
        }
    }
}
