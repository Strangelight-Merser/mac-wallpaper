/// Raw LZ4 block decompression (no frame header), as used inside TEX mipmaps.
enum LZ4 {
    static func decompressBlock(_ src: ArraySlice<UInt8>, decompressedSize: Int) throws -> [UInt8] {
        var dst = [UInt8](repeating: 0, count: decompressedSize)
        var ip = src.startIndex
        let end = src.endIndex
        var op = 0

        func readLength(_ base: Int) throws -> Int {
            var len = base
            if base == 15 {
                while true {
                    guard ip < end else { throw WEFormatError.corrupt("lz4 length") }
                    let b = Int(src[ip]); ip += 1
                    len += b
                    if b != 255 { break }
                }
            }
            return len
        }

        while ip < end {
            let token = Int(src[ip]); ip += 1
            let litLen = try readLength(token >> 4)
            guard ip + litLen <= end, op + litLen <= decompressedSize else {
                throw WEFormatError.corrupt("lz4 literal overflow")
            }
            for k in 0..<litLen { dst[op + k] = src[ip + k] }
            ip += litLen
            op += litLen
            if ip >= end { break } // last sequence has literals only

            guard ip + 2 <= end else { throw WEFormatError.corrupt("lz4 offset") }
            let distance = Int(src[ip]) | Int(src[ip + 1]) << 8
            ip += 2
            guard distance > 0, distance <= op else { throw WEFormatError.corrupt("lz4 distance") }
            let matchLen = try readLength(token & 15) + 4
            guard op + matchLen <= decompressedSize else { throw WEFormatError.corrupt("lz4 match overflow") }
            // Byte-wise copy handles overlapping matches.
            var m = op - distance
            for _ in 0..<matchLen { dst[op] = dst[m]; op += 1; m += 1 }
        }
        guard op == decompressedSize else {
            throw WEFormatError.corrupt("lz4 produced \(op) of \(decompressedSize) bytes")
        }
        return dst
    }
}
