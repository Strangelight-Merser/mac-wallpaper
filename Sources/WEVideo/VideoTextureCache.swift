import CryptoKit
import Foundation

/// Disk backing for embedded video payloads. The borrowed bytes are never retained.
public enum VideoTextureCache {
    public static func store(_ bytes: [UInt8]) throws -> URL {
        guard !bytes.isEmpty else { throw VideoError.decode("empty video payload") }
        return try bytes.withUnsafeBytes { buffer in
            // Hash all bytes without making another payload-sized allocation.
            let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: buffer.baseAddress!),
                            count: buffer.count, deallocator: .none)
            let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MacWallpaper/video-textures", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(key + ".mp4")
            if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic) }
            return url
        }
    }
}
