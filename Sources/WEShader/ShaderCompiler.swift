import CShaderTools
import CryptoKit
import Foundation

/// Uniform block member as laid out in SPIR-V (offsets are honoured by the generated MSL struct).
public struct UniformMember {
    public let name: String
    public let type: String      // float, vec2, vec3, vec4, mat4, int, ...
    public let offset: Int
    public let arrayCount: Int   // 1 when not an array
    public let arrayStride: Int
}

/// One compiled stage: MSL source plus the bindings the renderer needs.
public struct CompiledStage {
    public let msl: String
    public let entryPoint: String
    public let uniformBufferIndex: Int?
    public let uniformBlockSize: Int
    public let uniforms: [UniformMember]
    /// sampler2D name → (MSL texture index, MSL sampler index)
    public let textures: [String: (texture: Int, sampler: Int)]
    /// vertex attribute name → [[attribute(n)]]
    public let attributes: [String: Int]
}

public struct CompiledProgram {
    public let vertex: CompiledStage
    public let fragment: CompiledStage
}

public enum ShaderCompileError: Error, CustomStringConvertible {
    case tool(String, String)
    public var description: String {
        switch self { case .tool(let t, let log): return "\(t) failed:\n\(log)" }
    }
}

/// GLSL → SPIR-V → MSL via glslang + SPIRV-Cross. By default both run in-process (CShaderTools); the
/// command-line tools remain available as a reference (`WE_SHADER_BACKEND=cli`) and for parity checks
/// (`WE_SHADER_PARITY=1` compiles with both and reports any difference).
public enum ShaderCompiler {
    /// Cumulative wall time per stage (seconds) and number of programs compiled — for WE_TIMING.
    public nonisolated(unsafe) static var timings: [String: Double] = [:]
    public nonisolated(unsafe) static var programsCompiled = 0
    public nonisolated(unsafe) static var parityMismatches: [String] = []

    static func timed<T>(_ stage: String, _ body: () throws -> T) rethrows -> T {
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { timings[stage, default: 0] += CFAbsoluteTimeGetCurrent() - t0 }
        return try body()
    }

    static let environment = ProcessInfo.processInfo.environment
    static let useCLI = environment["WE_SHADER_BACKEND"] == "cli"
    static let checkParity = environment["WE_SHADER_PARITY"] != nil

    /// Versions of the in-process compilers (part of the shader cache key).
    public static let toolsVersion = String(cString: we_shader_tools_version())

    /// Backend output before any of our post-processing: MSL text and JSON reflection per stage.
    struct RawOutput: Codable, Equatable {
        let vertexMSL, vertexReflection, fragmentMSL, fragmentReflection: String
    }

    public static func compile(vertex: String, fragment: String) throws -> CompiledProgram {
        let key = cacheKey(vertex: vertex, fragment: fragment)
        if let cached = timed("cache read", { readCache(key) }) {
            switch cached {
            case .success(let raw): return program(from: raw)
            case .failure(let log): throw ShaderCompileError.tool("glslang", log)
            }
        }
        programsCompiled += 1
        let raw: RawOutput
        do {
            raw = try useCLI
                ? timed("compile (cli)") { try compileCLI(vertex: vertex, fragment: fragment) }
                : timed("compile (in-process)") { try compileInProcess(vertex: vertex, fragment: fragment) }
        } catch ShaderCompileError.tool(let stage, let log) {
            writeCache(key, .failure("\(stage): \(log)"))
            throw ShaderCompileError.tool(stage, log)
        }
        writeCache(key, .success(raw))
        if checkParity && !useCLI {
            let reference = try compileCLI(vertex: vertex, fragment: fragment)
            if reference != raw {
                let which = [("vertex MSL", reference.vertexMSL == raw.vertexMSL),
                             ("vertex reflection", reference.vertexReflection == raw.vertexReflection),
                             ("fragment MSL", reference.fragmentMSL == raw.fragmentMSL),
                             ("fragment reflection", reference.fragmentReflection == raw.fragmentReflection)]
                    .filter { !$0.1 }.map(\.0)
                parityMismatches.append("\(which.joined(separator: ", ")) differ for program #\(programsCompiled)")
            }
        }
        return program(from: raw)
    }

    // MARK: - disk cache

    /// Bump when the backend invocation changes (flags, MSL version...) to invalidate old entries.
    static let pipelineRevision = "glsl2msl-1"

    /// `~/Library/Caches/MacWallpaper/shaders`; `WE_SHADER_CACHE=off` disables, any other value is a path.
    public static let cacheDirectory: URL? = {
        switch environment["WE_SHADER_CACHE"] {
        case "off"?: return nil
        case let path?: return URL(fileURLWithPath: path)
        case nil:
            return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("MacWallpaper/shaders")
        }
    }()

    enum CacheEntry: Codable {
        case success(RawOutput)
        case failure(String)
    }

    static func cacheKey(vertex: String, fragment: String) -> String {
        var h = SHA256()
        for part in [pipelineRevision, useCLI ? "cli" : toolsVersion, vertex, fragment] {
            h.update(data: Data(part.utf8))
            h.update(data: Data([0]))
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func readCache(_ key: String) -> CacheEntry? {
        guard let dir = cacheDirectory,
              let data = try? Data(contentsOf: dir.appendingPathComponent(key + ".json")) else { return nil }
        return try? JSONDecoder().decode(CacheEntry.self, from: data)
    }

    static func writeCache(_ key: String, _ entry: CacheEntry) {
        guard let dir = cacheDirectory, let data = try? JSONEncoder().encode(entry) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Write-then-rename keeps concurrent readers from seeing partial files.
        let tmp = dir.appendingPathComponent(key + "." + UUID().uuidString + ".tmp")
        guard (try? data.write(to: tmp)) != nil else { return }
        _ = try? FileManager.default.replaceItemAt(dir.appendingPathComponent(key + ".json"), withItemAt: tmp)
    }

    static func program(from raw: RawOutput) -> CompiledProgram {
        let vertex = parseStage(msl: raw.vertexMSL, reflection: raw.vertexReflection)
        let fragment = parseStage(msl: raw.fragmentMSL, reflection: raw.fragmentReflection)
        return CompiledProgram(vertex: padVertexOutputs(vertex, for: fragment), fragment: fragment)
    }

    static func compileInProcess(vertex: String, fragment: String) throws -> RawOutput {
        var out = we_compile_glsl_pair(vertex, fragment)
        defer { we_shader_output_free(&out) }
        guard out.ok != 0 else { throw ShaderCompileError.tool("glslang", out.log.map { String(cString: $0) } ?? "") }
        return RawOutput(vertexMSL: String(cString: out.vertex_msl), vertexReflection: String(cString: out.vertex_reflection),
                         fragmentMSL: String(cString: out.fragment_msl), fragmentReflection: String(cString: out.fragment_reflection))
    }

    // MARK: - command-line backend (reference)

    static let toolDirs = ["/opt/homebrew/bin", "/usr/local/bin"]

    static func tool(_ name: String) -> String {
        toolDirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? name
    }

    static func compileCLI(vertex: String, fragment: String) throws -> RawOutput {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("weshader-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let v = dir.appendingPathComponent("s.vert"), f = dir.appendingPathComponent("s.frag")
        try vertex.write(to: v, atomically: true, encoding: .utf8)
        try fragment.write(to: f, atomically: true, encoding: .utf8)

        // Link both stages so varying locations are matched by name. Loose uniforms go into one
        // default block (one Metal buffer) — see design.md §6.5.
        let (code, log) = run(tool("glslangValidator"),
                              ["-V", "-R", "--sdub", "WEUniforms", "0", "0", "--aml", "--amb", "-l",
                               v.path, f.path], cwd: dir)
        guard code == 0 else { throw ShaderCompileError.tool("glslang", log) }
        func cross(_ spv: URL) throws -> (String, String) {
            let out = spv.deletingPathExtension().appendingPathExtension("metal")
            var (code, log) = run(tool("spirv-cross"), [spv.path, "--msl", "--msl-version", "20300", "--output", out.path], cwd: dir)
            guard code == 0 else { throw ShaderCompileError.tool("spirv-cross", log) }
            let msl = try String(contentsOf: out, encoding: .utf8)
            (code, log) = run(tool("spirv-cross"), [spv.path, "--reflect"], cwd: dir)
            guard code == 0 else { throw ShaderCompileError.tool("spirv-cross --reflect", log) }
            return (msl, log)
        }
        let (vm, vr) = try cross(dir.appendingPathComponent("vert.spv"))
        let (fm, fr) = try cross(dir.appendingPathComponent("frag.spv"))
        return RawOutput(vertexMSL: vm, vertexReflection: vr, fragmentMSL: fm, fragmentReflection: fr)
    }

    // MARK: - parsing

    static func parseStage(msl rawMSL: String, reflection: String) -> CompiledStage {
        let msl = fixAddressSpaces(rawMSL)
        let refl = (try? JSONSerialization.jsonObject(with: Data(reflection.utf8))) as? [String: Any] ?? [:]

        var members: [UniformMember] = []
        var blockSize = 0
        if let ubo = (refl["ubos"] as? [[String: Any]])?.first,
           let typeKey = ubo["type"] as? String,
           let type = (refl["types"] as? [String: Any])?[typeKey] as? [String: Any] {
            blockSize = ubo["block_size"] as? Int ?? 0
            for m in type["members"] as? [[String: Any]] ?? [] {
                members.append(UniformMember(name: m["name"] as? String ?? "", type: m["type"] as? String ?? "",
                                             offset: m["offset"] as? Int ?? 0,
                                             arrayCount: (m["array"] as? [Int])?.first ?? 1,
                                             arrayStride: m["array_stride"] as? Int ?? 0))
            }
        }

        // MSL indices are assigned by SPIRV-Cross; read them back from the entry point signature.
        var textures: [String: (Int, Int)] = [:]
        var tex: [String: Int] = [:], smp: [String: Int] = [:]
        for m in matches(#"(\w+)\s+\[\[texture\((\d+)\)\]\]"#, msl) { tex[m[1]] = Int(m[2]) }
        for m in matches(#"(\w+)Smplr\s+\[\[sampler\((\d+)\)\]\]"#, msl) { smp[m[1]] = Int(m[2]) }
        for (k, t) in tex { textures[k] = (t, smp[k] ?? t) }
        var attrs: [String: Int] = [:]
        for m in matches(#"(\w+)\s+\[\[attribute\((\d+)\)\]\]"#, msl) { attrs[m[1]] = Int(m[2]) }
        let buffer = matches(#"constant\s+WEUniforms&\s+\w+\s+\[\[buffer\((\d+)\)\]\]"#, msl).first.flatMap { Int($0[1]) }

        return CompiledStage(msl: msl, entryPoint: "main0", uniformBufferIndex: buffer,
                             uniformBlockSize: blockSize, uniforms: members,
                             textures: textures.mapValues { (texture: $0.0, sampler: $0.1) }, attributes: attrs)
    }

    /// Metal rejects a pipeline whose fragment shader reads a `[[user(locnN)]]` the vertex shader does not
    /// write (WE shaders do this under some combos). Add the missing members to the vertex output struct;
    /// `main0_out out = {};` zero-initialises them.
    static func padVertexOutputs(_ vertex: CompiledStage, for fragment: CompiledStage) -> CompiledStage {
        func members(_ msl: String, _ structName: String) -> [String: String] {
            guard let r = msl.range(of: "struct \(structName)\n{"), let end = msl[r.upperBound...].range(of: "};") else { return [:] }
            var out: [String: String] = [:]
            for m in matches(#"(\w+)\s+\w+\s+\[\[user\((locn\d+)\)[^\]]*\]\];"#, String(msl[r.upperBound..<end.lowerBound])) {
                out[m[2]] = m[1]
            }
            return out
        }
        let have = members(vertex.msl, "main0_out"), need = members(fragment.msl, "main0_in")
        let missing = need.filter { have[$0.key] == nil }
        guard !missing.isEmpty, let r = vertex.msl.range(of: "struct main0_out\n{\n") else { return vertex }
        let extra = missing.sorted { $0.key < $1.key }.map { "    \($0.value) _pad_\($0.key) [[user(\($0.key))]];\n" }.joined()
        var msl = vertex.msl
        msl.insert(contentsOf: extra, at: r.upperBound)
        return CompiledStage(msl: msl, entryPoint: vertex.entryPoint, uniformBufferIndex: vertex.uniformBufferIndex,
                             uniformBlockSize: vertex.uniformBlockSize, uniforms: vertex.uniforms,
                             textures: vertex.textures, attributes: vertex.attributes)
    }

    /// SPIRV-Cross forwards globals to helpers as `thread const T&`, which cannot bind to uniforms in
    /// `constant`. Pass those by value instead (read-only, so equivalent).
    static func fixAddressSpaces(_ src: String) -> String {
        let re = try! NSRegularExpression(pattern: #"thread const ([\w:<>, ]+?)& (\w+)(?=[,)])"#)
        return src.components(separatedBy: "\n").map { line -> String in
            guard let c = line.first, !" \t#".contains(c), line.contains("("), line.contains("thread const"),
                  !line.hasPrefix("fragment"), !line.hasPrefix("vertex"), !line.hasPrefix("struct"),
                  !line.hasPrefix("template") else { return line }
            return re.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "$1 $2")
        }.joined(separator: "\n")
    }

    static func matches(_ pattern: String, _ s: String) -> [[String]] {
        let re = try! NSRegularExpression(pattern: pattern)
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
            (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? "" }
        }
    }

    static func run(_ exe: String, _ args: [String], cwd: URL) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = cwd
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(exe): \(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
