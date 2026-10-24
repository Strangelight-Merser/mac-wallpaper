import XCTest
import simd
import WEFormat
import WEScript
@testable import WERender

private func animationModelData() -> Data {
    var data = Data()
    func word(_ value: UInt32) { var n = value.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
    func string(_ value: String) { data.append(contentsOf: value.utf8); data.append(0) }
    func floats(_ values: [Float]) { values.forEach { word($0.bitPattern) } }
    string("MDLV0013"); word(1); word(0); word(0); string("material.json"); word(0); word(52)
    floats([0, 0, 0]); (0..<4).forEach { _ in word(0) }; floats([1, 0, 0, 0, 0, 0]); word(6)
    data.append(contentsOf: [0, 0, 0, 0, 0, 0])
    string("MDLS0001"); word(0); data.append(contentsOf: [1, 0, 0, 0])
    string("root"); word(0); word(.max); word(64)
    floats([1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]); string("")
    string("MDLA0001"); word(0); word(2)
    for id in 1...2 {
        word(UInt32(id)); word(0); string("motion\(id)"); string("loop"); floats([2]); word(2); word(0); word(1)
        word(0); word(72)
        floats([Float(id * 10),0,0, 0,0,0, 1,1,1])
        floats([Float(id * 20),0,0, 0,0,Float.pi / 2, 2,2,2]); word(0)
    }
    return data
}

private func animationModel() throws -> PuppetModel { try PuppetModel(data: animationModelData()) }

private final class PuppetHost: SceneScriptHost {
    let state: PuppetAnimationState
    var values: [String: ScriptValue] = [:]
    var errors: [String] = []
    init(_ state: PuppetAnimationState) { self.state = state }
    var objectIDs: [Int] { [1, 2] }
    func objectID(named name: String) -> Int? { name == "puppet" ? 1 : nil }
    func objectName(_ id: Int) -> String? { id == 1 ? "puppet" : "plain" }
    func parentID(of id: Int) -> Int? { nil }
    func value(object: Int, property: String) -> ScriptValue? { values[property] }
    func setValue(_ value: ScriptValue, object: Int, property: String) { values[property] = value }
    func transformMatrix(object: Int) -> simd_double4x4 { matrix_identity_double4x4 }
    func animation(object: Int) -> ScriptAnimationHost? { nil }
    func animationLayerCommand(object: Int, command: String, arguments: [String: Any]) -> Any? {
        object == 1 ? state.command(command, arguments: arguments) : nil
    }
    func log(_ level: ScriptLogLevel, _ message: String) { if level == .error { errors.append(message) } }
    func sortLayer(object: Int, index: Int) {}
    func effectIndex(object: Int, named name: String) -> Int? { nil }
    func sceneValue(_ property: String) -> ScriptValue? { nil }
    func setSceneValue(_ value: ScriptValue, property: String) {}
}

final class AnimationLayerTests: XCTestCase {
    func assertMatrices(_ a: [simd_float4x4], _ b: [simd_float4x4], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        for (a, b) in zip(a, b) {
            for c in 0..<4 { for r in 0..<4 { XCTAssertEqual(a[c][r], b[c][r], accuracy: 0.00001, file: file, line: line) } }
        }
    }

    func testDeterministicUncontrolledTimeline() throws {
        let model = try animationModel()
        let layers: [PuppetModel.Layer] = [.init(animation: 1, rate: -0.7, blend: 0.25), .init(animation: 2, rate: 2, blend: 0.5)]
        let state = PuppetAnimationState(model: model, layers: layers)
        for t in [0, 0.25, 9, -0.5, 0.25, 100, 0] {
            state.prepare(time: t)
            assertMatrices(state.matrices, model.matrices(layers: layers, time: t))
        }
    }

    func testBlendInOutPauseAndRestart() throws {
        let state = PuppetAnimationState(model: try animationModel(), layers: [
            .init(animation: 1, blendin: true, blendout: true, blendtime: 2)])
        let track = try XCTUnwrap(state.tracks.first)
        XCTAssertEqual(track.envelope, 0)
        state.prepare(time: 1); XCTAssertEqual(track.envelope, 0.5)
        track.pause(); let pose = state.matrices
        state.prepare(time: 2); assertMatrices(state.matrices, pose)
        track.play(); state.prepare(time: 3); XCTAssertEqual(track.envelope, 0.75)
        track.stop(); XCTAssertFalse(track.playing); XCTAssertEqual(track.frame, 0)
        XCTAssertEqual(track.layer.blend, 1)
        state.prepare(time: 4); XCTAssertEqual(track.envelope, 0.375)
        track.stop()
        state.prepare(time: 5); XCTAssertEqual(track.envelope, 0)
        assertMatrices(state.matrices, [matrix_identity_float4x4])
        track.play(); state.prepare(time: 6); XCTAssertEqual(track.envelope, 0.5)
        state.prepare(time: 7); XCTAssertEqual(track.envelope, 1)
        state.prepare(time: 0); XCTAssertEqual(track.envelope, 1)
    }

    func testAdditiveUsesFrameZeroDeltaWithoutConsumingBaseWeight() throws {
        let model = try animationModel()
        let state = PuppetAnimationState(model: model, layers: [.init(animation: 2, blend: 0.5, additive: true)])
        assertMatrices(state.matrices, [matrix_identity_float4x4])
        state.prepare(time: 0.5)
        let pose = state.matrices[0]
        XCTAssertEqual(pose.columns.3.x, 10, accuracy: 0.0001)
        XCTAssertEqual(simd_length(SIMD3(pose.columns.0.x, pose.columns.0.y, pose.columns.0.z)), 1.5, accuracy: 0.0001)
        XCTAssertEqual(pose.columns.0.x, 1.5 / sqrt(2), accuracy: 0.0001)
        let layers: [PuppetModel.Layer] = [.init(animation: 1), .init(animation: 2, blend: 0.5, additive: true)]
        let combined = model.matrices(layers: layers, times: [0, 0.5])[0]
        XCTAssertEqual(combined.columns.3.x, 20, accuracy: 0.0001)
    }

    func testScriptControlsSyntheticSceneAndNextFrameSnapshot() throws {
        let model = try animationModel()
        let state = PuppetAnimationState(model: model, layers: [.init(animation: 1, name: "idle")])
        let host = PuppetHost(state)
        let engine = SceneScriptEngine(host: host, userProperties: [:], canvasSize: .init(64, 64), storageURL: nil)
        engine.addScript(object: 1, path: "result", source: """
        let a;
        export function init() {
            a=thisScene.getLayer('puppet').getAnimationLayer('idle');
            if(a!==thisLayer.getAnimationLayer(0)) throw Error('identity');
            if(thisLayer.getAnimationLayer(9)!==undefined) throw Error('missing');
            return [thisLayer.getAnimationLayerCount(),a.name,a.rate,a.blend,a.visible,a.frameCount,a.fps,a.duration,a.isPlaying()].join(':');
        }
        export function update() {
            if(shared.action==='pause') a.pause();
            if(shared.action==='seek') a.setFrame(0.25);
            if(shared.action==='rate') {a.rate=2;a.play();}
            if(shared.action==='blend') {a.pause();a.blend=0.25;}
            if(shared.action==='hide') a.visible=false;
            if(shared.action==='stop') {a.visible=true;a.stop();}
        }
        export function cursorClick() { shared.action=thisLayer.action; }
        """, initialValue: .null)
        XCTAssertEqual(host.values["result"], .string("1:idle:1:1:true:2:2:1:true"))
        func tick(_ t: Double, _ action: String) {
            state.prepare(time: t)
            host.values["action"] = .string(action)
            engine.cursorEvent(.click, object: 1, world: .zero)
            engine.update(frameTime: 0.25, runtime: t, date: Date(timeIntervalSince1970: 0), cursorWorld: .zero)
        }
        tick(0.25, "pause")
        let paused = state.matrices
        tick(0.5, ""); assertMatrices(state.matrices, paused)
        tick(0.75, "seek"); assertMatrices(state.matrices, paused)
        tick(1, ""); assertMatrices(state.matrices, model.matrices(layers: [.init(animation: 1)], time: 0.125))
        tick(1, "rate"); tick(1.125, "")
        XCTAssertEqual(state.tracks[0].frame, 0.75, accuracy: 0.0001)
        tick(1.125, "blend"); tick(1.25, "")
        assertMatrices(state.matrices, model.matrices(layers: [.init(animation: 1, blend: 0.25)], time: 0.375))
        tick(1.25, "hide"); tick(1.5, ""); assertMatrices(state.matrices, [matrix_identity_float4x4])
        tick(1.5, "stop"); tick(2, "")
        XCTAssertEqual(state.tracks[0].frame, 0); XCTAssertEqual(state.tracks[0].layer.blend, 0.25)
        assertMatrices(state.matrices, model.matrices(layers: [.init(animation: 1, blend: 0.25)], time: 0))
        XCTAssertTrue(host.errors.isEmpty, "\(host.errors)")
    }

    func testExternalPuppetProjectWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["WE_PUPPET_PROJECT"] else {
            throw XCTSkip("WE_PUPPET_PROJECT not provided")
        }
        let project = URL(fileURLWithPath: path)
        let assets = ProcessInfo.processInfo.environment["WE_PUPPET_ASSETS"].map { URL(fileURLWithPath: $0) }
        let locator = AssetLocator(project: project, assets: assets)
        let scene = try SceneDescription(project: project, locator: locator)
        let layers = scene.layers.filter { $0.puppet != nil }
        XCTAssertFalse(layers.isEmpty)
        for layer in layers {
            let model = try XCTUnwrap(layer.puppet)
            let state = PuppetAnimationState(model: model, layers: layer.animationLayers)
            for time in [0.0, 0.25, 1, 10, 0.25] {
                state.prepare(time: time)
                XCTAssertEqual(state.matrices.count, model.bones.count)
                for matrix in state.matrices {
                    for c in 0..<4 { for r in 0..<4 { XCTAssertTrue(matrix[c][r].isFinite) } }
                }
                assertMatrices(state.matrices, model.matrices(layers: layer.animationLayers, time: time))
            }
            print("External puppet \(layer.id): \(model.bones.count) bones, \(state.tracks.count) animation layers")
        }
    }

    func testSceneLayerOptionsAndIndependentImageStates() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func json(_ name: String, _ value: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: folder.appendingPathComponent(name))
        }
        try json("project.json", ["file": "scene.json", "type": "scene"])
        try json("model.json", ["puppet": "puppet.mdl", "material": "material.json"])
        try json("material.json", ["passes": []])
        try json("scene.json", ["objects": [1, 2].map { id in
            ["id": id, "image": "model.json", "animationlayers": [
                ["animation": 1, "id": 42, "name": "idle", "additive": true,
                 "blendin": true, "blendout": true, "blendtime": 2, "rate": 0.5, "blend": 0.25, "visible": false]
            ]] as [String: Any]
        }])
        let model = try animationModel()
        try animationModelData().write(to: folder.appendingPathComponent("puppet.mdl"))
        let scene = try SceneDescription(project: folder, locator: AssetLocator(project: folder, assets: nil))
        let layer = try XCTUnwrap(scene.layers.first?.animationLayers.first)
        XCTAssertEqual(layer.id, 42); XCTAssertEqual(layer.name, "idle")
        XCTAssertTrue(layer.additive); XCTAssertTrue(layer.blendin); XCTAssertTrue(layer.blendout)
        XCTAssertEqual(layer.blendtime, 2); XCTAssertEqual(layer.rate, 0.5); XCTAssertEqual(layer.blend, 0.25)
        XCTAssertFalse(layer.visible)
        let a = PuppetAnimationState(model: model, layers: scene.layers[0].animationLayers)
        let b = PuppetAnimationState(model: model, layers: scene.layers[1].animationLayers)
        a.tracks[0].pause(); a.prepare(time: 1); b.prepare(time: 1)
        XCTAssertEqual(a.tracks[0].time, 0); XCTAssertEqual(b.tracks[0].time, 0.5)
    }

    func testScriptCreateDestroyStableHandlesAndInvalidInputs() throws {
        let state = PuppetAnimationState(model: try animationModel(), layers: [.init(animation: 1, name: "same")])
        let host = PuppetHost(state)
        let engine = SceneScriptEngine(host: host, userProperties: [:], canvasSize: .init(64, 64), storageURL: nil)
        engine.addScript(object: 1, path: "result", source: """
        export function init() {
            const first=thisLayer.getAnimationLayer(0);
            const a=thisLayer.createAnimationLayer({animation:'motion2',name:'same',rate:-2,blend:0.5,visible:false,additive:true,blendin:true,blendout:true,blendtime:2});
            if(!a.isPlaying() || a.name!=='same' || a.rate!==-2 || a.blend!==0.5 || a.visible) throw Error('properties');
            if(thisLayer.getAnimationLayer('same')!==first) throw Error('duplicate');
            if(thisScene.getLayer(2).destroyAnimationLayer(a)) throw Error('owner');
            if(!thisLayer.destroyAnimationLayer(0) || thisLayer.getAnimationLayer(0)!==a) throw Error('index');
            if(thisLayer.destroyAnimationLayer(first)) throw Error('stale destroy');
            first.rate=9;
            if(a.rate!==-2) throw Error('stale mutation');
            a.rate=NaN;a.blend=Infinity;a.setFrame(Infinity);
            if(a.rate!==-2 || a.blend!==0.5 || a.getFrame()!==0) throw Error('nonfinite');
            if(thisLayer.getAnimationLayer(-1)!==undefined || thisLayer.getAnimationLayer(0.5)!==undefined) throw Error('index validation');
            if(thisLayer.destroyAnimationLayer(0.5)) throw Error('destroy validation');
            const b=thisLayer.createAnimationLayer(1);
            const c=thisLayer.createAnimationLayer('motion2');
            if(!thisLayer.destroyAnimationLayer(b) || !thisLayer.destroyAnimationLayer(c)) throw Error('destroy');
            let threw=false;try {thisLayer.createAnimationLayer('missing');} catch(e){threw=true;}
            if(!threw) throw Error('unknown animation');
            return thisLayer.getAnimationLayerCount();
        }
        """, initialValue: .null)
        XCTAssertEqual(host.values["result"], .number(1)); XCTAssertTrue(host.errors.isEmpty, "\(host.errors)")
        XCTAssertEqual(state.matrices[0].columns.3.x, 10)
        XCTAssertTrue(state.tracks[0].layer.additive)
        XCTAssertTrue(state.tracks[0].layer.blendin); XCTAssertTrue(state.tracks[0].layer.blendout)
        XCTAssertEqual(state.tracks[0].layer.blendtime, 2)
        state.prepare(time: 1); XCTAssertEqual(state.tracks[0].envelope, 0.5)
        assertMatrices(state.matrices, [matrix_identity_float4x4])
        engine.addScript(object: 1, path: "pose", source: """
        export function init() { const a=thisLayer.getAnimationLayer(0);a.visible=true;a.pause();a.setFrame(1); }
        """, initialValue: .null)
        assertMatrices(state.matrices, [matrix_identity_float4x4])
        state.prepare(time: 1)
        XCTAssertEqual(state.matrices[0].columns.3.x, 5, accuracy: 0.0001)
        engine.addScript(object: 1, path: "destroy", source: """
        export function init() { return thisLayer.destroyAnimationLayer(0); }
        """, initialValue: .null)
        XCTAssertEqual(host.values["destroy"], .bool(true))
        XCTAssertEqual(state.matrices[0].columns.3.x, 5, accuracy: 0.0001)
        state.prepare(time: 1); assertMatrices(state.matrices, [matrix_identity_float4x4])
        XCTAssertTrue(host.errors.isEmpty, "\(host.errors)")
    }
}
