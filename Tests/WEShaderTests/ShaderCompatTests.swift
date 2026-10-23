import Foundation
import XCTest
import WEFormat
@testable import WEShader

final class ShaderCompatTests: XCTestCase {
    private let vertex = "void main() { gl_Position = vec4(0.0, 0.0, 0.0, 1.0); }"
    private let fragment = "void main() { gl_FragColor = vec4(1.0); }"

    private func preprocess(_ source: String, _ stage: ShaderPreprocessor.Stage,
                            overrides: [String: Int] = [:]) throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("fixture.\(stage.rawValue)")
        try source.write(to: url, atomically: true, encoding: .utf8)
        return try XCTUnwrap(ShaderPreprocessor.process(String(contentsOf: url, encoding: .utf8), stage: stage,
                                                       fileDirectory: "", locator: AssetLocator(project: root, assets: nil),
                                                       overrides: overrides)).source
    }

    private func repaired(_ v: String, _ f: String) -> (String, String) {
        ShaderPreprocessor.reconcileVaryings(vertex: ShaderPreprocessor.fixImplicitTruncation(v),
                                             fragment: ShaderPreprocessor.fixImplicitTruncation(f))
    }

    @discardableResult
    private func assertRepair(vertex v: String? = nil, fragment f: String? = nil,
                              error: String, file: StaticString = #filePath, line: UInt = #line) throws -> (String, String) {
        let vs = try preprocess(v ?? vertex, .vertex), fs = try preprocess(f ?? fragment, .fragment)
        XCTAssertThrowsError(try ShaderCompiler.compile(vertex: vs, fragment: fs), file: file, line: line) {
            XCTAssertTrue(String(describing: $0).contains(error), "\($0)", file: file, line: line)
        }
        let pair = repaired(vs, fs)
        XCTAssertNoThrow(try ShaderCompiler.compile(vertex: pair.0, fragment: pair.1), file: file, line: line)
        return pair
    }

    func testCRLFStageOnlyCombo() throws {
        let v = """
        // [COMBO] {"combo":"SAMPLES","default":1}
        #if SAMPLES == 1
        varying vec2 uv[2];
        #else
        varying vec2 uv[3];
        #endif
        void main() {
            gl_Position = vec4(0.0, 0.0, 0.0, 1.0);
            for (int i = 0; i < uv.length(); ++i) uv[i] = vec2(float(i));
        }
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let f = """
        #if SAMPLES == 1
        varying vec2 uv[2];
        #else
        varying vec2 uv[3];
        #endif
        void main() { gl_FragColor = vec4(uv[1], 0.0, 1.0); }
        """
        let declared = ShaderPreprocessor.scan(v).combos.merging(ShaderPreprocessor.scan(f).combos) { a, _ in a }
        let vs = try preprocess(v, .vertex, overrides: declared), fs = try preprocess(f, .fragment, overrides: declared)
        XCTAssertThrowsError(try ShaderCompiler.compile(vertex: vs, fragment: fs))
        let pair = repaired(vs, fs)
        XCTAssertTrue(pair.1.contains("#define SAMPLES 1\n"))
        XCTAssertNoThrow(try ShaderCompiler.compile(vertex: pair.0, fragment: pair.1))
        let explicitV = try preprocess(v, .vertex, overrides: ["SAMPLES": 0])
        let explicitF = try preprocess(f, .fragment, overrides: ["SAMPLES": 0])
        let unchanged = ShaderPreprocessor.reconcileVaryings(vertex: explicitV, fragment: explicitF)
        XCTAssertEqual(unchanged.0, explicitV)
        XCTAssertEqual(unchanged.1, explicitF)
        XCTAssertNoThrow(try ShaderCompiler.compile(vertex: explicitV, fragment: explicitF))
    }

    func testBoolArithmetic() throws {
        let pair = try assertRepair(fragment: """
        uniform float threshold;
        void main() {
            bool enabled = threshold > 0.0;
            float value = (threshold < 0.75) * 2.0 + 3.0 * enabled;
            if (enabled) value += 1.0;
            gl_FragColor = vec4(value);
        }
        """, error: "wrong operand types")
        XCTAssertTrue(pair.1.contains("float((threshold < 0.75))"))
        XCTAssertTrue(pair.1.contains("if (enabled)"))
    }

    func testRuntimeGlobalConstantsAndDependencies() throws {
        let pair = try assertRepair(vertex: """
        uniform float amount;
        #define CONTROL amount
        const float scale = 4.0;
        const vec2 offsets = vec2(scale, CONTROL);
        const float weight = offsets.y * 2.0;
        void main() { gl_Position = vec4(offsets, weight, 1.0); }
        """, error: "global const initializers must be constant")
        XCTAssertTrue(pair.0.contains("const float scale = 4.0;"))
        XCTAssertFalse(pair.0.contains("const vec2 offsets"))
        XCTAssertFalse(pair.0.contains("const float weight"))
    }

    func testFloatRemainderAndIntegerDestination() throws {
        let pair = try assertRepair(fragment: """
        uniform float position;
        #define PERIOD 5
        void main() {
            uint slot = position % PERIOD;
            uint nextSlot = (slot + 1) % PERIOD;
            uint untouched = (slot + 1u) % 5u;
            float negative = (-position) % -2.0;
            gl_FragColor = vec4(float(slot), float(nextSlot), negative, 1.0);
        }
        """, error: "wrong operand types")
        XCTAssertTrue(pair.1.contains("uint(WE_compatRemainder"))
        XCTAssertTrue(pair.1.contains("(slot + 1u) % 5u"))
        XCTAssertTrue(pair.1.contains("(slot + uint(1)) % uint(PERIOD)"))
        XCTAssertTrue(pair.1.contains("return x - y * trunc(x / y);"))
        let compiled = try ShaderCompiler.compile(vertex: pair.0, fragment: pair.1)
        XCTAssertTrue(compiled.fragment.msl.contains("trunc("))
        XCTAssertFalse(compiled.fragment.msl.contains("mod("))
        XCTAssertFalse(compiled.fragment.msl.contains("floor("))
    }

    func testRemainderPrecedenceAndSingleEvaluation() throws {
        let pair = try assertRepair(fragment: """
        float counter = 0.0;
        float nextValue() { counter += 1.0; return counter; }
        void main() {
            float value = 3.0 * nextValue() % 2.0 % -1.5;
            gl_FragColor = vec4(value);
        }
        """, error: "wrong operand types")
        XCTAssertEqual(pair.1.components(separatedBy: "nextValue()").count - 1, 2)
        XCTAssertTrue(pair.1.contains("float(3.0 * nextValue())"))
        XCTAssertEqual(ShaderPreprocessor.fixImplicitTruncation(pair.1), pair.1)
    }

    func testGlobalInitializerCallingUserFunction() throws {
        let pair = try assertRepair(vertex: """
        float coefficient(float x) { return x * x; }
        const float fixedScale = 2.0;
        const float dynamicScale = coefficient(fixedScale);
        void main() { gl_Position = vec4(dynamicScale, 0.0, 0.0, 1.0); }
        """, error: "global const initializers must be constant")
        XCTAssertTrue(pair.0.contains("const float fixedScale = 2.0;"))
        XCTAssertFalse(pair.0.contains("const float dynamicScale"))
    }

    func testScalarMixEndpoints() throws {
        let pair = try assertRepair(fragment: """
        uniform vec3 tint;
        uniform float strength;
        void main() {
            vec3 color = mix(0.25, tint * (1.0 + strength), strength);
            color = lerp(color, 0.5, strength);
            gl_FragColor = vec4(color, 1.0);
        }
        """, error: "no matching overloaded function")
        XCTAssertTrue(pair.1.contains("mix(vec3(0.25),"))
        XCTAssertTrue(pair.1.contains("lerp(color, vec3(0.5),"))
    }

    func testWiderVertexVaryingAfterMixRepair() throws {
        let pair = try assertRepair(vertex: """
        varying vec4 uv;
        void main() { gl_Position = vec4(0.0, 0.0, 0.0, 1.0); uv = vec4(0.5); }
        """, fragment: """
        varying vec2 uv;
        void main() {
            vec2 point = uv;
            vec2 color = mix(0.25, uv.xy + point, 0.5);
            gl_FragColor = vec4(color, 0.0, 1.0);
        }
        """, error: "no matching overloaded function")
        XCTAssertTrue(pair.1.contains("varying vec4 uv;"))
        XCTAssertTrue(pair.1.contains("vec2 point = uv.xy;"))
        XCTAssertTrue(pair.1.contains("uv.xy + point"))
    }

    func testValidCodeAndCommentsUnchanged() throws {
        let raw = """
        const float scale = 2.0;
        const vec2 offset = vec2(scale, 1.0);
        // bool arithmetic: (a < b) * 4.0; float remainder: x % 2;
        /* mix(0.5, tint, 1.0); const float dynamic = uniformValue; */
        void main() {
            int index = 7 % 3;
            bool enabled = index > 0;
            vec3 color = mix(vec3(0.0), vec3(1.0), 0.5);
            color = mix(color, vec3(0.0), bvec3(enabled));
            if (enabled) color *= scale;
            gl_FragColor = vec4(color + vec3(offset, 0.0), 1.0);
        }
        """
        let vs = try preprocess(vertex, .vertex), fs = try preprocess(raw, .fragment)
        let pair = repaired(vs, fs)
        XCTAssertEqual(pair.0, vs)
        XCTAssertEqual(pair.1, fs)
        let before = try ShaderCompiler.compile(vertex: vs, fragment: fs)
        let after = try ShaderCompiler.compile(vertex: pair.0, fragment: pair.1)
        XCTAssertEqual(before.vertex.msl, after.vertex.msl)
        XCTAssertEqual(before.fragment.msl, after.fragment.msl)
    }
}
