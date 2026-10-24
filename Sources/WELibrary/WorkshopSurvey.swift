import Foundation
import WESteam

/// Filename evidence is a usage estimate, not proof that an asset is referenced by the scene.
public struct WorkshopSurvey: Sendable {
    public struct Assessment: Codable, Sendable, Equatable {
        public var features: [String]
        public var blockers: [Feature]
        public var unknown: [String]
        public var notes: [String]
    }
    public struct Record: Codable, Sendable {
        public let item: WorkshopItem
        public let files: [String]
        public let assessment: Assessment
        public let error: String?
        public init(item: WorkshopItem, files: [String], assessment: Assessment, error: String? = nil) {
            self.item = item; self.files = files; self.assessment = assessment; self.error = error
        }
    }
    public struct Row: Codable, Sendable {
        public let feature: String
        public let wallpapersUsing: Int
        public let onlyKnownBlocker: Int
        public let support: String
    }
    public struct Report: Codable, Sendable {
        public let checkerVersion: Int
        public let records: [Record]
        public let rows: [Row]
        public let undeterminedCount: Int
        public let undeterminedShare: Double
        public let suggestedDownloads: [WorkshopItem]
        public let suggestedTotalBytes: Int64
        public let initialProbeBytes: Int64
        public let probeBudgetBytes: Int64
        public let reservedProbeBytes: Int64
    }

    public static func classify(names: [String], jsonFiles: [String: Data] = [:],
                                packageHeadersComplete: Bool = false) -> Assessment {
        var features = Set<String>(), blockers = Set<Feature>()
        // Unknown means scene.json couldn't be read (or the package table); how well scripts, particle operators
        // and custom shaders run can't be known without rendering, so those stay notes.
        var unknown = Set<String>()
        var notes = ["File names indicate assets present, not necessarily active scene objects."]
        let paths = names.map { $0.replacingOccurrences(of: "\\", with: "/").lowercased() }
        for path in paths {
            if path.hasPrefix("models/") && (path.hasSuffix(".mdl") || path.hasSuffix(".mdla")) {
                features.insert(Feature.model3D.rawValue)
                // .mdl is also used for 2D image meshes: JSON scene objects are needed to establish a blocker.
                notes.append("\(path): model asset; 3D usage and puppet data undecidable from name")
            }
            if path.hasPrefix("particles/") { features.insert(Feature.particles.rawValue) }
            if path.hasPrefix("sounds/") { features.insert(Feature.sound.rawValue) }
            if path.hasPrefix("shaders/") { features.insert("customShaders") }
            if path.hasPrefix("fonts/") || [".ttf", ".otf", ".woff", ".woff2"].contains(where: path.hasSuffix) {
                features.insert("fonts")
            }
        }
        if paths.contains(where: { $0.hasSuffix("scene.pkg") }) && !packageHeadersComplete {
            unknown.insert("packageContents")
        }
        var sceneRead = false
        for (path, bytes) in jsonFiles {
            guard let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                unknown.insert("invalidJSON"); continue
            }
            if path.lowercased() == "project.json", let type = root["type"] as? String, type.lowercased() != "scene" {
                notes.append("project.json type is \(type)")
            }
            guard path.lowercased() == "scene.json", let objects = root["objects"] as? [[String: Any]] else { continue }
            sceneRead = true
            if Self.containsKey("script", in: root) { features.insert(Feature.sceneScript.rawValue) }
            var models = false
            for object in objects {
                // Match CompatibilityChecker's object precedence.
                if object["particle"] != nil { features.insert(Feature.particles.rawValue); continue }
                if object["text"] != nil { features.insert(Feature.text.rawValue); continue }
                if object["sound"] != nil { features.insert(Feature.sound.rawValue); continue }
                if object["image"] == nil {
                    if object["model"] != nil {
                        features.insert(Feature.model3D.rawValue); blockers.insert(.model3D); models = true
                    }
                    else if object["light"] != nil { features.insert(Feature.light.rawValue); blockers.insert(.light) }
                }
            }
            // Image objects whose model has puppet data reference .mdl files; without 3D model objects in the
            // scene, .mdl files are puppet meshes.
            if !models, paths.contains(where: { $0.hasPrefix("models/") && $0.hasSuffix(".mdl") }) {
                features.remove(Feature.model3D.rawValue)
                features.insert(Feature.puppetWarp.rawValue); blockers.insert(.puppetWarp)
            }
        }
        if !sceneRead { unknown.insert("sceneObjects") }
        return Assessment(features: features.sorted(), blockers: blockers.sorted { $0.rawValue < $1.rawValue },
                          unknown: unknown.sorted(), notes: notes)
    }

    static func containsKey(_ key: String, in value: Any) -> Bool {
        if let object = value as? [String: Any] { return object[key] != nil || object.values.contains { containsKey(key, in: $0) } }
        if let array = value as? [Any] { return array.contains { containsKey(key, in: $0) } }
        return false
    }

    /// Exact minimum-cardinality cover over unsupported-feature evidence (including model filename candidates).
    /// Ties minimize advertised full download size; downloading the suggestion still requires user approval.
    public static func suggestions(_ records: [Record]) -> [WorkshopItem] {
        func targets(_ record: Record) -> Set<Feature> {
            Set(record.assessment.blockers).union(record.assessment.features.compactMap(Feature.init(rawValue:))
                .filter { [.model3D, .puppetWarp, .light].contains($0) })
        }
        let features = Set(records.flatMap { targets($0) }).sorted { $0.rawValue < $1.rawValue }
        guard !features.isEmpty else { return [] }
        var best: [Int: [WorkshopItem]] = [0: []]
        func bytes(_ items: [WorkshopItem]) -> UInt64 {
            items.reduce(0) { sum, item in
                let (n, overflow) = sum.addingReportingOverflow(UInt64(max(0, item.fileSize)))
                return overflow ? UInt64.max : n
            }
        }
        for record in records.sorted(by: { $0.item.id < $1.item.id }) {
            let mask = features.enumerated().reduce(0) { $0 | (targets(record).contains($1.element) ? 1 << $1.offset : 0) }
            guard mask != 0 else { continue }
            for (covered, items) in Array(best) {
                let combined = covered | mask, candidate = items + [record.item]
                if let old = best[combined], old.count < candidate.count || (old.count == candidate.count && bytes(old) <= bytes(candidate)) { continue }
                best[combined] = candidate
            }
        }
        return (best[(1 << features.count) - 1] ?? []).sorted { $0.id < $1.id }
    }

    public static func report(records: [Record], initialProbeBytes: Int64 = 0,
                              probeBudgetBytes: Int64 = 0, reservedProbeBytes: Int64 = 0) -> Report {
        let support: [String: String] = ["model3D": "unsupported", "puppetWarp": "unsupported", "light": "unsupported",
            "particles": "supported subset; operators unknown", "text": "supported", "sound": "supported",
            "sceneScript": "supported (most of the API)", "videoTexture": "supported",
            "customShaders": "compiler-dependent; unknown", "fonts": "supported"]
        let all = Set(support.keys).union(records.flatMap { $0.assessment.features })
        let rows = all.sorted().map { feature in
            Row(feature: feature, wallpapersUsing: records.filter { $0.assessment.features.contains(feature) }.count,
                onlyKnownBlocker: records.filter { $0.assessment.blockers.count == 1 && $0.assessment.blockers[0].rawValue == feature }.count,
                support: support[feature] ?? "unknown")
        }
        let unknown = records.filter { !$0.assessment.unknown.isEmpty || $0.error != nil }.count
        let suggestions = suggestions(records)
        let total = suggestions.reduce(Int64(0)) { sum, item in
            let (value, overflow) = sum.addingReportingOverflow(max(0, item.fileSize))
            return overflow ? Int64.max : value
        }
        return Report(checkerVersion: CompatibilityChecker.version, records: records, rows: rows,
            undeterminedCount: unknown, undeterminedShare: records.isEmpty ? 0 : Double(unknown) / Double(records.count),
            suggestedDownloads: suggestions, suggestedTotalBytes: total, initialProbeBytes: initialProbeBytes,
            probeBudgetBytes: probeBudgetBytes, reservedProbeBytes: reservedProbeBytes)
    }
}
