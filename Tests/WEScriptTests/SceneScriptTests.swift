import XCTest
import Foundation
import simd
@testable import WEScript

final class FakeAnimation: ScriptAnimationHost {
    var isPlaying = false
    var frame = 0.0
    var frameCount = 24.0
    var rate = 1.0
    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false; frame = 0 }
}

final class FakeHost: SceneScriptHost {
    var names = [1: "First", 2: "Second", 3: "Parent"]
    var objectIDs = [1, 2, 3]
    var values: [Int: [String: ScriptValue]] = [:]
    var scene: [String: ScriptValue] = ["clearColor": .vec3(.init(0.1, 0.2, 0.3)), "bloom": .bool(true)]
    var logs: [(ScriptLogLevel, String)] = []
    var animations: [Int: FakeAnimation] = [1: FakeAnimation(), 2: FakeAnimation()]
    func objectID(named name: String) -> Int? { names.first { $0.value == name }?.key }
    func objectName(_ id: Int) -> String? { names[id] }
    func parentID(of id: Int) -> Int? { id == 3 ? nil : 3 }
    func value(object: Int, property: String) -> ScriptValue? { values[object]?[property] }
    func setValue(_ value: ScriptValue, object: Int, property: String) { values[object, default: [:]][property] = value }
    func transformMatrix(object: Int) -> simd_double4x4 {
        var m = matrix_identity_double4x4; m.columns.3 = .init(11, 12, 13, 1); return m
    }
    func animation(object: Int) -> ScriptAnimationHost? { animations[object] }
    func log(_ level: ScriptLogLevel, _ message: String) { logs.append((level, message)) }
    func sortLayer(object: Int, index: Int) { objectIDs.removeAll { $0 == object }; objectIDs.insert(object, at: min(max(0, index), objectIDs.count)) }
    func effectIndex(object: Int, named name: String) -> Int? { name == "Glow" ? 1 : nil }
    func sceneValue(_ property: String) -> ScriptValue? { scene[property] }
    func setSceneValue(_ value: ScriptValue, property: String) { scene[property] = value }
}

final class SceneScriptTests: XCTestCase {
    func engine(_ host: FakeHost, users: [String: Any] = [:], storage: URL? = nil, clock: Date? = nil) -> SceneScriptEngine {
        SceneScriptEngine(host: host, userProperties: users, canvasSize: .init(800, 600), storageURL: storage, fixedClock: clock)
    }
    func tick(_ e: SceneScriptEngine, _ time: Double = 1) {
        e.update(frameTime: 0.1, runtime: time, date: Date(timeIntervalSince1970: 1_700_000_000), cursorWorld: .init(3, 4, 5))
    }
    @discardableResult
    func add(_ e: SceneScriptEngine, _ h: FakeHost, _ source: String, id: Int = 1, path: String = "text",
             initial: ScriptValue = .number(0), props: [String: Any] = [:]) -> ScriptValue {
        h.setValue(initial, object: id, property: path)
        return e.addScript(object: id, path: path, source: source, scriptProperties: props, initialValue: initial)
    }
    func assertClean(_ h: FakeHost, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(h.logs.filter { $0.0 == .error }.isEmpty, "\(h.logs)", file: file, line: line)
    }

    func testModulesScopeAndLexicalLiterals() {
        let h = FakeHost(), e = engine(h)
        let script = #"""
        'use strict';
        // export function bogus() {}
        /* import * as Nope from 'invalid'; */
        import * as M from 'WEMath';
        import { mix as blend, smoothStep } from "WEMath";
        import { Vec2 } from 'WEVector';
        export const a=2, b=3;
        export class Marker {}
        const literal = "export import";
        const template = `export ${`import ${1}`}`;
        const regex = /export\s+import/;
        function start(v) { return v+blend(a,b,0.5); }
        export { start as init };
        export let update = v => v+smoothStep(0,1,0.5)+new Vec2(2,4).x;
        export default function unused() { return literal; }
        """#
        XCTAssertEqual(add(e,h,script), .number(2.5))
        add(e,h,"export function update(v) { return v+10; }",id:2)
        tick(e)
        XCTAssertEqual(h.value(object:1,property:"text"), .number(5))
        XCTAssertEqual(h.value(object:2,property:"text"), .number(10))
        assertClean(h)
    }
    func testLifecycleCurrentHostValueAndUndefined() {
        let h=FakeHost(), e=engine(h)
        XCTAssertEqual(add(e,h,"export function init(v){return v+2;} export function update(v){return v+1;}",initial:.number(3)),.number(5))
        h.setValue(.number(20),object:1,property:"text"); tick(e)
        XCTAssertEqual(h.value(object:1,property:"text"),.number(21))
        add(e,h,"export function update(){thisLayer.alpha=0.4;}",path:"alpha",initial:.number(1)); tick(e)
        XCTAssertEqual(h.value(object:1,property:"alpha"),.number(0.4))
        XCTAssertEqual(add(e,h,"export function init(){return null;}",path:"nullable"),.null)
        add(e,h,"function update(){throw Error('not exported');}",id:2); tick(e)
        assertClean(h)
    }
    func testUserBindingsAndAllBuilderKinds() {
        let h=FakeHost(), e=engine(h,users:["enabled":true])
        add(e,h,"""
        export const scriptProperties=createScriptProperties()
          .addCheckbox({name:'flag',value:false}).addSlider({name:'amount',value:2})
          .addCombo({name:'choice',options:[{value:7}]}).addText({name:'label',value:'ok'})
          .addTextInput({name:'input',value:'text'}).addColor({name:'tint',value:new Vec3(0)})
          .addFile({name:'file',value:'a'}).addDirectory({name:'folder',value:'b'}).finish();
        let calls=0;
        export function applyUserProperties(changed){calls++;}
        export function update(){return scriptProperties.flag+':'+scriptProperties.amount+':'+calls+':'+scriptProperties.tint.x+':'+scriptProperties.choice;}
        """, props:["flag":["user":"enabled","value":false],"amount":9,"tint":"0.2 0.4 0.6"])
        tick(e); XCTAssertEqual(h.value(object:1,property:"text"),.string("true:9:1:0.2:7"))
        e.userPropertiesChanged(["enabled":false]); tick(e)
        XCTAssertEqual(h.value(object:1,property:"text"),.string("false:9:2:0.2:7")); assertClean(h)
    }
    func testSharedHostProxiesMaterialsAndScene() {
        let h=FakeHost(), e=engine(h)
        add(e,h,"""
        export function init(){ shared.counter=4; }
        export function update(){
            thisScene.getLayer('Second').visible=false;
            thisLayer.getEffect('Glow').visible=true;
            thisLayer.getMaterial(2).gain=3;
            thisScene.sortLayer(thisLayer,2);
            thisScene.clearColor=new Vec3(1,0,0);
            return thisLayer.getParent().id+thisLayer.getTransformMatrix().m[12]+thisScene.getLayerCount();
        }
        """)
        add(e,h,"export function update(){return ++shared.counter;}",id:2)
        add(e,h,"export function init(){thisObject.getMaterial(1).gain=7; thisObject.visible=false;}",path:"effects[0].passes[2].constantshadervalues.gain")
        tick(e)
        XCTAssertEqual(h.value(object:2,property:"text"),.number(5))
        XCTAssertEqual(h.value(object:1,property:"text"),.number(17))
        XCTAssertEqual(h.value(object:2,property:"visible"),.bool(false))
        XCTAssertEqual(h.value(object:1,property:"effects[1].visible"),.bool(true))
        XCTAssertEqual(h.value(object:1,property:"effects[0].passes[1].constantshadervalues.gain"),.number(7))
        XCTAssertEqual(h.value(object:1,property:"passes[2].constantshadervalues.gain"),.number(3))
        XCTAssertEqual(h.objectIDs,[2,3,1]); XCTAssertEqual(h.scene["clearColor"],.vec3(.init(1,0,0)))
        XCTAssertEqual(add(e,h,"export function init(){return thisScene.getLayer('Missing');}",path:"missing"),.null)
        assertClean(h)
    }
    func testVectorsMathAndColors() {
        let h=FakeHost(),e=engine(h)
        XCTAssertEqual(add(e,h,"export function init(v){return v.add(new Vec2(2,3)).multiply(2);}",initial:.vec2(.init(1,2))),.vec2(.init(6,10)))
        XCTAssertEqual(add(e,h,"export function init(v){let w=v.copy();w.a=8;return w.divide(2);}",initial:.vec4(.init(2,4,6,4))),.vec4(.init(1,2,3,4)))
        XCTAssertEqual(add(e,h,"export function init(){return new Vec3(1,0,0).cross(new Vec3(0,1,0));}"),.vec3(.init(0,0,1)))
        XCTAssertEqual(add(e,h,"export function init(){return new Vec3(2,4,8).subtract(1).mix(new Vec3(5,7,11),0.25);}"),.vec3(.init(2,4,8)))
        XCTAssertEqual(add(e,h,"export function init(){let v=new Vec2(3,4);return v.length()+v.lengthSqr()+v.normalize().dot(new Vec2(5,0));}"),.number(33))
        XCTAssertEqual(add(e,h,"import {hsv2rgb} from 'WEColor'; export function init(){return hsv2rgb(new Vec3(120,1,0.5));}"),.vec3(.init(0,0.5,0)))
        XCTAssertEqual(add(e,h,"import * as C from 'WEColor'; export function init(){return C.rgb2hsv(C.normalizeColor(new Vec3(0,0,255)));}"),.vec3(.init(240,1,1)))
        XCTAssertEqual(add(e,h,"import * as M from 'WEMath'; export function init(){return M.mix(2,6,0.25)+M.clamp(8,0,2)+M.smoothStep(1,0,0.5);}"),.number(5.5))
        assertClean(h)
    }
    func testTimersUseScriptTimeAndCancellation() {
        let h=FakeHost(),e=engine(h)
        add(e,h,"""
        let n=0;
        export function init(){
            let cancel=engine.setTimeout(()=>n+=1000,10); cancel();
            let id=engine.setInterval(()=>n+=100,10); engine.clearInterval(id);
            engine.setTimeout(()=>n+=10,500);
            engine.setInterval(()=>n++,200);
        }
        export function update(){return n;}
        """)
        tick(e,0.1); XCTAssertEqual(h.value(object:1,property:"text"),.number(0))
        tick(e,0.2); XCTAssertEqual(h.value(object:1,property:"text"),.number(1))
        tick(e,0.5); XCTAssertEqual(h.value(object:1,property:"text"),.number(12))
        tick(e,0.6); XCTAssertEqual(h.value(object:1,property:"text"),.number(12)); assertClean(h)
    }
    func testFixedClockAndTimeOfDay() {
        let h=FakeHost(), clock=Date(timeIntervalSince1970:1_700_000_123.25),e=engine(h,clock:clock)
        add(e,h,"export function update(){return Date.now()===new Date().getTime() ? Date.now() : 0;}")
        tick(e); XCTAssertEqual(h.value(object:1,property:"text"),.number(clock.timeIntervalSince1970*1000))
        let parts=Calendar.current.dateComponents([.hour,.minute,.second,.nanosecond],from:clock)
        let expected=(Double(parts.hour!*3600+parts.minute!*60+parts.second!)+0.25)/86400
        add(e,h,"export function update(){return engine.timeOfDay;}",path:"day");tick(e,100)
        guard case .number(let actual)=h.value(object:1,property:"day") else { return XCTFail() }
        XCTAssertEqual(actual,expected,accuracy:1e-9)
        XCTAssertEqual(add(e,h,"export function init(){return new Date(0).getTime()+Date.UTC(1970,0,1);}"),.number(0));assertClean(h)
    }
    func testStorageRoundTripAndLocations() throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".json")
        defer { try? FileManager.default.removeItem(at:url) }
        let h=FakeHost()
        do {
            let e=engine(h,storage:url)
            add(e,h,"export function init(){localStorage.set('v',new Vec3(2,3,4));localStorage.set('v',9,localStorage.LOCATION_SCREEN);}")
        }
        let e=engine(h,storage:url)
        XCTAssertEqual(add(e,h,"export function init(){return localStorage.get('v').multiply(2);}"),.vec3(.init(4,6,8)))
        XCTAssertEqual(add(e,h,"export function init(){localStorage.clear();return localStorage.get('v',localStorage.LOCATION_SCREEN);}"),.number(9))
        XCTAssertEqual(add(e,h,"export function init(){localStorage.delete('v',localStorage.LOCATION_SCREEN);return localStorage.get('v',localStorage.LOCATION_SCREEN);}"),.null)
        assertClean(h)
    }
    func testErrorsDisableOnlyFailingScriptAndTimers() {
        let h=FakeHost(),e=engine(h)
        XCTAssertEqual(add(e,h,"throw new Error('load');",path:"load",initial:.number(7)),.number(7))
        add(e,h,"export function update(){throw new Error('update');}",path:"bad")
        add(e,h,"export function init(){engine.setInterval(()=>{throw Error('timer');},1);}",path:"timer")
        add(e,h,"export function update(v){return v+1;}",id:2)
        for i in 1...3 { tick(e,Double(i)) }
        XCTAssertEqual(h.value(object:2,property:"text"),.number(3))
        XCTAssertEqual(h.logs.filter{$0.0 == .error}.count,3)
        XCTAssertTrue(h.logs.allSatisfy{$0.1.contains("First.")})
    }
    func testEventsAnimationAudioAndStubs() {
        let h=FakeHost(),e=engine(h)
        add(e,h,"""
        const b=engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_16);
        export function cursorClick(e){thisLayer.origin=e.worldPosition;thisLayer.getAnimation().play();}
        export function mediaPropertiesChanged(e){thisLayer.text=e.albumArtist;}
        export function mediaPlaybackChanged(e){thisLayer.visible=e.state===MediaPlaybackEvent.PLAYBACK_PLAYING;}
        export function mediaTimelineChanged(e){thisLayer.alpha=e.position/e.duration;}
        export function mediaThumbnailChanged(e){thisLayer.color=e.textColor;}
        export function update(){engine.registerAsset('unused');thisScene.createLayer();thisScene.destroyLayer();return b.average[0];}
        """,path:"audio")
        e.cursorEvent(.click,object:1,world:.init(7,8,9))
        e.mediaPropertiesChanged(title:"t",artist:"a",albumTitle:"b",albumArtist:"c")
        e.mediaPlaybackChanged(state:1);e.mediaTimelineChanged(position:3,duration:6)
        e.mediaThumbnailChanged(hasThumbnail:true,primaryColor:.zero,secondaryColor:.zero,tertiaryColor:.zero,textColor:.init(1,2,3),highContrastColor:.zero)
        e.update(frameTime:0.1,runtime:1,date:Date(),cursorWorld:.zero,audio:([Float](repeating:1,count:64),[Float](repeating:3,count:64)))
        XCTAssertEqual(h.value(object:1,property:"audio"),.number(2))
        XCTAssertEqual(h.value(object:1,property:"origin"),.vec3(.init(7,8,9)))
        XCTAssertEqual(h.value(object:1,property:"text"),.string("c"))
        XCTAssertEqual(h.value(object:1,property:"color"),.vec3(.init(1,2,3)))
        XCTAssertEqual(h.value(object:1,property:"alpha"),.number(0.5))
        XCTAssertEqual(h.value(object:1,property:"visible"),.bool(true))
        XCTAssertTrue(h.animations[1]!.isPlaying)
        tick(e);XCTAssertEqual(h.logs.filter{$0.0 == .warn}.count,3);assertClean(h)
    }
    func testRecursiveDiscovery() {
        let entry:[String:Any] = ["script":"export function update(v){return v;}","value":false,"scriptproperties":["a":1]]
        let found=ScriptedProperty.discover(in:["text":entry,"effects":[["visible":entry,"passes":[["constantshadervalues":["gain":entry]]]]],"instanceoverride":["count":entry]])
        XCTAssertEqual(found.map(\.path),["effects[0].passes[0].constantshadervalues.gain","effects[0].visible","instanceoverride.count","text"])
        XCTAssertEqual(found[0].staticValue as? Bool,false)
    }
    func testAdditionalModuleFormsAndUnexportedHook() {
        let h=FakeHost(), e=engine(h)
        XCTAssertEqual(add(e,h,"""
        export default function answer(){return 6;}
        export function init(){return answer();}
        """),.number(6))
        add(e,h,#"""
        export let a=1
        let unrelated=2, update=()=>{throw Error('private hook');};
        if (true) /export\s+function/.test('export function');
        const match=()=>/export/;
        """#,id:2)
        XCTAssertEqual(add(e,h,"export default function(){} export function init(){return 7;}"),.number(7))
        tick(e); assertClean(h)
    }
    func testLoadInitAndInvalidReturnFailuresKeepOtherScriptsAlive() {
        let h=FakeHost(), e=engine(h)
        XCTAssertEqual(add(e,h,"thisLayer.text='changed';throw Error('load');",initial:.string("static")),.string("static"))
        XCTAssertEqual(h.value(object:1,property:"text"),.string("static"))
        add(e,h,"export function init(){throw Error('init');}",path:"init")
        add(e,h,"export function update(){return {unsupported:true};}",path:"object")
        add(e,h,"export function {",path:"syntax")
        add(e,h,"export function update(v){return v+1;}",id:2)
        tick(e);tick(e)
        XCTAssertEqual(h.value(object:2,property:"text"),.number(2))
        XCTAssertEqual(h.logs.filter{$0.0 == .error}.count,4,"\(h.logs)")
    }
    func testAnimationPropertiesAndCursorTargeting() {
        let h=FakeHost(), e=engine(h)
        let source="""
        export function cursorDown(e){thisLayer.alpha=e.worldPosition.x;}
        export function cursorUp(){thisLayer.getAnimation().pause();}
        export function cursorMove(){thisLayer.getTextureAnimation().setFrame(4);}
        export function cursorEnter(){let a=thisLayer.getAnimation();a.rate=2;a.play();}
        export function cursorLeave(){thisLayer.getAnimation().stop();}
        export function update(){let a=thisLayer.getAnimation();return a.frameCount+a.getFrame()+a.rate+(a.isPlaying()?1:0);}
        """
        add(e,h,source);add(e,h,source,id:2)
        e.cursorEvent(.down,object:1,world:.init(9,0,0))
        XCTAssertEqual(h.value(object:1,property:"alpha"),.number(9))
        XCTAssertNil(h.value(object:2,property:"alpha"))
        e.cursorEvent(.move,object:1,world:.zero);e.cursorEvent(.enter,object:1,world:.zero);tick(e)
        XCTAssertEqual(h.value(object:1,property:"text"),.number(31))
        e.cursorEvent(.up,object:nil,world:.zero);XCTAssertFalse(h.animations[1]!.isPlaying)
        e.cursorEvent(.leave,object:1,world:.zero);XCTAssertEqual(h.animations[1]!.frame,0);assertClean(h)
    }
    func testEngineCanRunOffMainThread() {
        let done=expectation(description:"render thread")
        DispatchQueue(label:"WEScriptTests.render").async {
            let h=FakeHost()
            let e=SceneScriptEngine(host:h,userProperties:[:],canvasSize:.init(10,10),storageURL:nil)
            let result=e.addScript(object:1,path:"text",source:"export function init(v){return v+1;}",initialValue:.number(3))
            XCTAssertEqual(result,.number(4))
            XCTAssertEqual(h.value(object:1,property:"text"),.number(4))
            done.fulfill()
        }
        wait(for:[done],timeout:5)
    }
    func testPerformance100Scripts100Frames() {
        let h=FakeHost(),e=engine(h)
        for i in 0..<100 { add(e,h,"export function update(v){return v+engine.frametime;}",path:"p\(i)") }
        for i in 0..<10 { tick(e,Double(i)) }
        let start=ProcessInfo.processInfo.systemUptime
        for i in 0..<100 { tick(e,Double(i)) }
        let elapsed=ProcessInfo.processInfo.systemUptime-start
        print("WEScript 100 scripts: \(elapsed*10) ms/frame (100 frames)")
        XCTAssertLessThan(elapsed,2)
        assertClean(h)
    }
}
