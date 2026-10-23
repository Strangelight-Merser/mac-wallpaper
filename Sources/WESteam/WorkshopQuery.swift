import Foundation

public struct WorkshopQuery: Sendable, Equatable {
    public enum Sort: Sendable, Equatable {
        case trend(days: Int), popular, recent, updated, mostSubscribed, textRelevance
    }
    public var sort: Sort
    public var searchText: String?
    public var requiredTags: [String]
    public var excludedTags: [String]
    public var pageSize: Int
    public init(sort: Sort = .trend(days: 7), searchText: String? = nil,
                requiredTags: [String] = [], excludedTags: [String] = [], pageSize: Int = 100) {
        self.sort = sort; self.searchText = searchText; self.requiredTags = requiredTags
        self.excludedTags = excludedTags; self.pageSize = pageSize
    }
    func request(cursor: String) throws -> Data {
        guard (1...100).contains(pageSize), !cursor.isEmpty else { throw SteamError.malformed("workshop paging") }
        var p = ProtoWriter()
        let type: UInt64
        switch sort {
        case .popular: type = 0
        case .recent: type = 1
        case .trend(let days):
            guard (1...7).contains(days) else { throw SteamError.malformed("trend days must be 1...7") }
            type = 3; p.uint(14, UInt64(days))
        case .mostSubscribed: type = 9
        case .textRelevance: type = 12
        case .updated: type = 21
        }
        p.uint(1, type); p.uint(3, UInt64(pageSize)); p.uint(4, 431960); p.uint(5, 431960)
        requiredTags.forEach { p.string(6, $0) }; excludedTags.forEach { p.string(7, $0) }
        p.uint(8, 1)
        if let searchText { p.string(11, searchText) }
        for field in [17, 18, 20, 22, 32, 37, 38] { p.uint(field, 1) }
        p.string(39, cursor)
        return p.data
    }
}

public struct WorkshopPage: Sendable, Codable {
    public let items: [WorkshopItem]
    public let total: Int
    public let nextCursor: String?
    static func parse(_ data: Data) throws -> WorkshopPage {
        let p = try ProtoReader(data)
        guard p.contains(1), p.uint(1) <= UInt32.max else { throw SteamError.malformed("workshop total") }
        let items = try p.repeated(2).map { data -> WorkshopItem in
            let v = try ProtoReader(data)
            guard v.uint(2) > 0, v.uint(5) <= UInt32.max, v.uint(8) <= Int64.max,
                  v.uint(1) <= Int32.max else { throw SteamError.malformed("workshop item") }
            let tags = try v.repeated(52).map { try ProtoReader($0).string(1) }.filter { !$0.isEmpty }
            var preview = v.string(11)
            if preview.isEmpty {
                for bytes in v.repeated(51) {
                    let image = try ProtoReader(bytes)
                    if image.uint(7) == 0, !image.string(3).isEmpty { preview = image.string(3); break }
                }
            }
            var item = WorkshopItem(id: v.uint(2), appID: UInt32(v.uint(5)), title: v.string(16),
                fileSize: Int64(v.uint(8)), timeUpdated: Date(timeIntervalSince1970: Double(v.uint(20))),
                contentManifestID: v.uint(14), previewURL: preview.isEmpty ? nil : URL(string: preview),
                tags: tags, result: Int(v.uint(1, default: 2)))
            item.creatorID = v.contains(3) ? v.uint(3) : nil
            item.shortDescription = v.contains(18) ? v.string(18) : nil
            item.timeCreated = v.contains(19) ? Date(timeIntervalSince1970: Double(v.uint(19))) : nil
            item.subscriptions = v.contains(36) ? v.uint(36) : nil
            item.favorites = v.contains(37) ? v.uint(37) : nil
            item.metadata = v.contains(58) ? v.string(58) : nil
            if v.contains(55) {
                let votes = try ProtoReader(v.bytes(55))
                if votes.contains(1) {
                    guard votes.uint(1) <= UInt32.max else { throw SteamError.malformed("vote score") }
                    let score = Float(bitPattern: UInt32(votes.uint(1)))
                    guard score.isFinite else { throw SteamError.malformed("vote score") }
                    item.voteScore = Double(score)
                }
                item.votesUp = votes.contains(2) ? votes.uint(2) : nil
                item.votesDown = votes.contains(3) ? votes.uint(3) : nil
            }
            return item
        }
        return WorkshopPage(items: items, total: Int(p.uint(1)), nextCursor: p.string(3).isEmpty ? nil : p.string(3))
    }
}

public struct WorkshopBrowser: Sendable {
    private let client: SteamCMClient
    public init(client: SteamCMClient) { self.client = client }
    public func query(_ q: WorkshopQuery, cursor: String = "*") async throws -> WorkshopPage {
        try WorkshopPage.parse(await client.callService("PublishedFile.QueryFiles#1", q.request(cursor: cursor)))
    }
    static func subscriptionRequest(_ id: UInt64) throws -> Data {
        guard id > 0 else { throw SteamError.malformed("workshop id") }
        var p = ProtoWriter(); p.uint(1, id); p.uint(2, 1); p.uint(3, 431960); p.uint(4, 1)
        return p.data
    }
    public func subscribe(_ id: UInt64) async throws {
        _ = try ProtoReader(await client.callService("PublishedFile.Subscribe#1", Self.subscriptionRequest(id)))
    }
    public func unsubscribe(_ id: UInt64) async throws {
        _ = try ProtoReader(await client.callService("PublishedFile.Unsubscribe#1", Self.subscriptionRequest(id)))
    }
}
