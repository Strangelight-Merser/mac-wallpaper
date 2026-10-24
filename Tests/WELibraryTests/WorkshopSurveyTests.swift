import Foundation
import XCTest
import WESteam
@testable import WELibrary

final class WorkshopSurveyTests: XCTestCase {
    func record(_ id: UInt64, _ size: Int64, _ blockers: [Feature]) -> WorkshopSurvey.Record {
        let item = WorkshopItem(id: id, appID: 431960, title: "test", fileSize: size, timeUpdated: .distantPast, contentManifestID: 1)
        return .init(item: item, files: [], assessment: .init(features: blockers.map(\.rawValue), blockers: blockers, unknown: [], notes: []))
    }
    func testFilenameEvidenceDoesNotInventBlockers() {
        let a = WorkshopSurvey.classify(names: ["models/a.mdl", "models/b.mdla", "particles/a.json", "sounds/a.ogg", "shaders/test.frag", "fonts/test.ttf", "scene.pkg", "materials/video.tex"])
        XCTAssertEqual(Set(a.features), Set(["model3D", "particles", "sound", "customShaders", "fonts"]))
        XCTAssertTrue(a.blockers.isEmpty)
        // Without scene.json, what the scene does is undetermined.
        XCTAssertEqual(Set(a.unknown), ["sceneObjects", "packageContents"])
        let b = WorkshopSurvey.classify(names: ["scene.pkg", "sounds/a.ogg"], packageHeadersComplete: true)
        XCTAssertFalse(b.unknown.contains("packageContents"))
    }
    func testJSONClassificationAndOnlyBlocker() {
        let scene = Data(#"{"objects":[{"model":"models/a.mdl"},{"particle":"p"},{"sound":"s"},{"text":"hello"}]}"#.utf8)
        let a = WorkshopSurvey.classify(names: [], jsonFiles: ["scene.json": scene])
        XCTAssertEqual(a.blockers, [.model3D]); XCTAssertFalse(a.unknown.contains("light"))
        XCTAssertTrue(a.features.contains("text")); XCTAssertTrue(a.features.contains("particles"))
        let report = WorkshopSurvey.report(records: [record(1, 10, [.model3D]), record(2, 20, [.model3D, .light])])
        let row = report.rows.first { $0.feature == "model3D" }
        XCTAssertEqual(row?.wallpapersUsing, 2); XCTAssertEqual(row?.onlyKnownBlocker, 1)
        XCTAssertEqual(report.suggestedDownloads.map(\.id), [2])
        XCTAssertTrue(a.unknown.isEmpty)
        let known = WorkshopSurvey.Record(item: record(3, 1, []).item, files: [], assessment: a)
        XCTAssertEqual(WorkshopSurvey.report(records: [known]).undeterminedShare, 0)
        let namesOnly = WorkshopSurvey.Record(item: record(4, 1, []).item, files: [],
                                              assessment: WorkshopSurvey.classify(names: ["sounds/a.ogg"]))
        XCTAssertEqual(WorkshopSurvey.report(records: [namesOnly]).undeterminedShare, 1)
        XCTAssertEqual(WorkshopSurvey.report(records: []).undeterminedShare, 0)
    }
    func testPuppetMeshesAndScripts() {
        let scene = Data(#"{"objects":[{"image":"models/girl.json","origin":{"script":"x","value":"0 0 0"}}]}"#.utf8)
        let puppet = WorkshopSurvey.classify(names: ["models/girl.mdl", "models/girl.json"], jsonFiles: ["scene.json": scene])
        XCTAssertEqual(puppet.blockers, [.puppetWarp]); XCTAssertFalse(puppet.features.contains("model3D"))
        XCTAssertTrue(puppet.features.contains("sceneScript"))
        // With a 3D model object in the scene, .mdl files are that model's.
        let mixed = Data(#"{"objects":[{"model":"models/car.json"}]}"#.utf8)
        let model = WorkshopSurvey.classify(names: ["models/car.mdl"], jsonFiles: ["scene.json": mixed])
        XCTAssertEqual(model.blockers, [.model3D]); XCTAssertFalse(model.features.contains("sceneScript"))
    }
    func testFilenameCandidateSuggestedWithoutClaimingKnownBlocker() {
        let assessment = WorkshopSurvey.classify(names: ["models/mesh.mdl"])
        let candidate = WorkshopSurvey.Record(item: record(8, 20, []).item, files: ["models/mesh.mdl"], assessment: assessment)
        let report = WorkshopSurvey.report(records: [candidate])
        XCTAssertEqual(report.suggestedDownloads.map(\.id), [8])
        XCTAssertEqual(report.rows.first { $0.feature == "model3D" }?.onlyKnownBlocker, 0)
    }
    func testExactCoverAndSizeTieBreak() {
        let input = [record(1, 100, [.model3D]), record(2, 50, [.light]), record(3, 500, [.model3D, .light]),
                     record(4, 200, [.model3D, .light]), record(5, 30, [.puppetWarp])]
        let report = WorkshopSurvey.report(records: input)
        XCTAssertEqual(report.suggestedDownloads.map(\.id), [4, 5]); XCTAssertEqual(report.suggestedTotalBytes, 230)
        XCTAssertEqual(WorkshopSurvey.suggestions([]).count, 0)
    }
}
