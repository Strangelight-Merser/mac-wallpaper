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

/// GLSL → SPIR-V → MSL via the glslang / SPIRV-Cross command-line tools.
/// Prototype only: the app will link both libraries in-process (see docs/design.md §4.2).
public enum ShaderCompiler {
    static let toolDirs = ["/opt/homebrew/bin", "/usr/local/bin"]

    static func tool(_ name: String) -> String {
        toolDirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? name
    }

    public static func compile(vertex: String, fragment: String) throws -> CompiledProgram {
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
        var vertex = try cross(dir.appendingPathComponent("vert.spv"), dir: dir)
        let fragment = try cross(dir.appendingPathComponent("frag.spv"), dir: dir)
        vertex = padVertexOutputs(vertex, for: fragment)
        return CompiledProgram(vertex: vertex, fragment: fragment)
    }

    static func cross(_ spv: URL, dir: URL) throws -> CompiledStage {
        let out = spv.deletingPathExtension().appendingPathExtension("metal")
        var (code, log) = run(tool("spirv-cross"), [spv.path, "--msl", "--msl-version", "20300", "--output", out.path], cwd: dir)
        guard code == 0 else { throw ShaderCompileError.tool("spirv-cross", log) }
        let msl = fixAddressSpaces(try String(contentsOf: out, encoding: .utf8))
        (code, log) = run(tool("spirv-cross"), [spv.path, "--reflect"], cwd: dir)
        guard code == 0, let refl = try JSONSerialization.jsonObject(with: Data(log.utf8)) as? [String: Any] else {
            throw ShaderCompileError.tool("spirv-cross --reflect", log)
        }

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
