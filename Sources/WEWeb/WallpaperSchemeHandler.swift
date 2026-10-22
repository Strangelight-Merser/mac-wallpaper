import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves one wallpaper folder as `wewallpaper://wallpaper/<path>`.
///
/// Pages loaded from file:// get an opaque origin, so WebKit treats their own files as cross-origin:
/// CSS `mask-image`, `fetch`/XHR of local JSON, canvas reads of images all fail. Serving the folder
/// from a custom scheme gives page and files one origin, without private WebKit preferences.
/// Supports byte ranges (needed by <video>/<audio>); paths cannot leave the folder.
final class WallpaperSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "wewallpaper"
    static let host = "wallpaper"
    let root: URL

    init(root: URL) { self.root = root.standardizedFileURL.resolvingSymlinksInPath() }

    static func url(for file: URL, root: URL) -> URL? {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = file.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        var c = URLComponents()
        c.scheme = scheme
        c.host = host
        c.path = String(path.dropFirst(rootPath.count))
        return c.url
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let file = resolve(url) else {
            return fail(task, 404)
        }
        guard let handle = try? FileHandle(forReadingFrom: file),
              let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue else {
            return fail(task, 404)
        }
        defer { try? handle.close() }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        var headers = ["Content-Type": mime, "Accept-Ranges": "bytes", "Access-Control-Allow-Origin": "*",
                       "Cache-Control": "no-cache"]
        var status = 200
        var range = 0..<size
        if let header = task.request.value(forHTTPHeaderField: "Range"), let r = Self.parseRange(header, size: size) {
            range = r
            status = 206
            headers["Content-Range"] = "bytes \(r.lowerBound)-\(r.upperBound - 1)/\(size)"
        }
        headers["Content-Length"] = String(range.count)
        do {
            try handle.seek(toOffset: UInt64(range.lowerBound))
            let data = try handle.read(upToCount: range.count) ?? Data()
            task.didReceive(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
            task.didReceive(data)
            task.didFinish()
        } catch {
            fail(task, 500)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    /// Map a request URL to a file inside `root` (nil if missing or outside).
    func resolve(_ url: URL) -> URL? {
        guard url.host == Self.host else { return nil }
        let relative = url.path.removingPercentEncoding ?? url.path
        let file = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/") else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir) else { return nil }
        return isDir.boolValue ? file.appendingPathComponent("index.html") : file
    }

    /// "bytes=a-b", "bytes=a-", "bytes=-n" → half-open range clamped to the file.
    static func parseRange(_ header: String, size: Int) -> Range<Int>? {
        guard header.hasPrefix("bytes="), size > 0 else { return nil }
        let spec = header.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty, let n = Int(parts[1]) { return max(0, size - n)..<size }
        guard let start = Int(parts[0]), start < size else { return nil }
        let end = parts[1].isEmpty ? size - 1 : min(size - 1, Int(parts[1]) ?? size - 1)
        return end >= start ? start..<(end + 1) : nil
    }

    func fail(_ task: WKURLSchemeTask, _ code: Int) {
        task.didReceive(HTTPURLResponse(url: task.request.url ?? URL(string: "about:blank")!, statusCode: code,
                                        httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"])!)
        task.didFinish()
    }
}
