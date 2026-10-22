import Foundation

/// Minimal WebM / Matroska demuxer: the first video track's codec info and its frames, enough to
/// feed VideoToolbox. Audio and other tracks are ignored.
public struct WebMFile {
    public struct Packet {
        public let pts: Double          // seconds
        public let range: Range<Int>    // byte range in `data`
        public let keyframe: Bool
    }

    public let codecID: String          // "V_VP9", "V_AV1", "V_VP8", ...
    public let codecPrivate: Data
    public let width: Int
    public let height: Int
    /// Frames in file (decode) order.
    public let packets: [Packet]
    public let duration: Double
    /// Packets skipped because they used Matroska lacing (not used for video in practice).
    public let lacedPacketsSkipped: Int
    public let data: Data

    public func bytes(_ p: Packet) -> Data { data.subdata(in: p.range) }

    public enum ParseError: Error, CustomStringConvertible {
        case notEBML, noVideoTrack
        public var description: String {
            switch self {
            case .notEBML: return "not a WebM/Matroska file"
            case .noVideoTrack: return "no video track"
            }
        }
    }

    public init(url: URL) throws { try self.init(data: Data(contentsOf: url, options: .mappedIfSafe)) }

    public init(data: Data) throws {
        var parser = Parser(data: data)
        try parser.run()
        guard let track = parser.video else { throw ParseError.noVideoTrack }
        self.data = data
        codecID = track.codec
        codecPrivate = track.codecPrivate
        width = track.width
        height = track.height
        packets = parser.packets
        lacedPacketsSkipped = parser.laced
        let frameDuration = track.defaultDuration > 0 ? Double(track.defaultDuration) / 1e9 : 0
        let lastPTS = parser.packets.map(\.pts).max() ?? 0
        let declared = parser.durationTicks * parser.timecodeScale / 1e9
        // Prefer the declared segment duration; otherwise last frame + one frame.
        duration = declared > 0 ? declared : lastPTS + (frameDuration > 0 ? frameDuration : 1.0 / 30)
    }

    // MARK: - EBML

    struct Track {
        var number: UInt64 = 0, type: UInt64 = 0, codec = "", codecPrivate = Data()
        var width = 0, height = 0, defaultDuration: UInt64 = 0
    }

    struct Parser {
        let data: Data
        var video: Track?
        var packets: [Packet] = []
        var laced = 0
        var timecodeScale = 1_000_000.0
        var durationTicks = 0.0
        var clusterTime = 0.0

        // Master elements we descend into.
        static let masters: Set<UInt64> = [0x18538067 /* Segment */, 0x1654AE6B /* Tracks */,
                                           0x1F43B675 /* Cluster */, 0x1549A966 /* Info */]

        init(data: Data) { self.data = data }

        mutating func run() throws {
            // EBML header must come first.
            var p = data.startIndex
            guard let (id, _) = vint(&p, keepMarker: true), id == 0x1A45DFA3 else { throw ParseError.notEBML }
            parse(from: data.startIndex, to: data.endIndex)
        }

        /// Variable-length integer; `keepMarker` for element IDs, not for sizes. Returns (value, isUnknownSize).
        func vint(_ p: inout Int, keepMarker: Bool) -> (UInt64, Bool)? {
            guard p < data.endIndex else { return nil }
            let first = data[p]
            var length = 1
            while length <= 8, first & (0x80 >> (length - 1)) == 0 { length += 1 }
            guard length <= 8, p + length <= data.endIndex else { return nil }
            var value = UInt64(keepMarker ? first : first & (0xFF >> length))
            for i in 1..<length { value = value << 8 | UInt64(data[p + i]) }
            p += length
            let unknown = !keepMarker && value == (UInt64(1) << (7 * UInt64(length))) - 1
            return (value, unknown)
        }

        func uint(_ range: Range<Int>) -> UInt64 { range.reduce(0) { $0 << 8 | UInt64(data[$1]) } }

        func float(_ range: Range<Int>) -> Double {
            let bits = uint(range)
            return range.count == 4 ? Double(Float(bitPattern: UInt32(bits))) : Double(bitPattern: bits)
        }

        /// Children of the element body `start..<end` as (id, body range).
        func children(_ start: Int, _ end: Int) -> [(id: UInt64, range: Range<Int>)] {
            var out: [(UInt64, Range<Int>)] = []
            var p = start
            while p < end {
                guard let (id, _) = vint(&p, keepMarker: true), let (size, unknown) = vint(&p, keepMarker: false) else { break }
                let stop = unknown ? end : min(end, p + Int(clamping: size))
                out.append((id, p..<stop))
                p = stop
            }
            return out
        }

        mutating func parse(from start: Int, to end: Int) {
            for (id, range) in children(start, end) {
                switch id {
                case _ where Self.masters.contains(id): parse(from: range.lowerBound, to: range.upperBound)
                case 0xAE: // TrackEntry
                    let t = track(range)
                    if t.type == 1, video == nil { video = t }
                case 0x2AD7B1: timecodeScale = Double(uint(range))    // TimecodeScale
                case 0x4489: durationTicks = float(range)              // Duration
                case 0xE7: clusterTime = Double(uint(range))           // Cluster Timecode
                case 0xA3: block(range, keyframe: { $0 & 0x80 != 0 }) // SimpleBlock: keyframe flag
                case 0xA0:                                             // BlockGroup
                    let kids = children(range.lowerBound, range.upperBound)
                    // A Block is a keyframe unless the group references another frame (ReferenceBlock).
                    let referenced = kids.contains { $0.id == 0xFB }
                    for kid in kids where kid.id == 0xA1 { block(kid.range, keyframe: { _ in !referenced }) }
                default: break
                }
            }
        }

        func track(_ range: Range<Int>) -> Track {
            var t = Track()
            for (id, r) in children(range.lowerBound, range.upperBound) {
                switch id {
                case 0xD7: t.number = uint(r)                                    // TrackNumber
                case 0x83: t.type = uint(r)                                      // TrackType (1 = video)
                case 0x86: t.codec = String(decoding: data[r], as: UTF8.self)    // CodecID
                case 0x63A2: t.codecPrivate = data.subdata(in: r)                // CodecPrivate
                case 0x23E383: t.defaultDuration = uint(r)                       // DefaultDuration (ns)
                case 0xE0:                                                       // Video
                    for (vid, vr) in children(r.lowerBound, r.upperBound) {
                        if vid == 0xB0 { t.width = Int(uint(vr)) }               // PixelWidth
                        if vid == 0xBA { t.height = Int(uint(vr)) }              // PixelHeight
                    }
                default: break
                }
            }
            return t
        }

        mutating func block(_ range: Range<Int>, keyframe: (UInt8) -> Bool) {
            guard let video, range.count > 4 else { return }
            var p = range.lowerBound
            guard let (trackNumber, _) = vint(&p, keepMarker: false), trackNumber == video.number,
                  p + 3 <= range.upperBound else { return }
            let relative = Int16(bitPattern: UInt16(uint(p..<(p + 2))))
            let flags = data[p + 2]
            guard flags & 0x06 == 0 else { laced += 1; return }
            let pts = (clusterTime + Double(relative)) * timecodeScale / 1e9
            packets.append(Packet(pts: pts, range: (p + 3)..<range.upperBound, keyframe: keyframe(flags)))
        }
    }
}
