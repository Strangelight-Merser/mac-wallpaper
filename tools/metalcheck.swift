// Compiles each .metal file given on argv with MTLDevice.makeLibrary(source:) — the same path
// the app uses at runtime. Prints "OK <file>" or "FAIL <file>\t<first error line>".
import Foundation
import Metal

guard let device = MTLCreateSystemDefaultDevice() else { print("no Metal device"); exit(1) }
let opts = MTLCompileOptions()
opts.languageVersion = .version2_3
for path in CommandLine.arguments.dropFirst() {
    do {
        let src = try String(contentsOfFile: path, encoding: .utf8)
        _ = try device.makeLibrary(source: src, options: opts)
        print("OK \(path)")
    } catch {
        let msg = "\(error)".split(separator: "\n").first { $0.contains("error:") } ?? Substring("\(error)")
        print("FAIL \(path)\t\(msg.prefix(200))")
    }
}
