import Foundation
import Darwin

struct ChunkPeekFailure: Error {
    let underlying: Error
    let bytesRead: Int
    let retryable: Bool
}

struct ChunkPeek: Sendable {
    var port: UInt16 = 80
    var timeout: TimeInterval = 10
    func peek(server: ContentServer, depot: UInt32, sha: Data, key: Data,
              enough: @escaping @Sendable (Data) throws -> Bool, maxBytes: Int) async throws -> (plaintext: Data, bytesRead: Int) {
        let worker = Task.detached {
            try read(server: server, depot: depot, sha: sha, key: key, enough: enough, maxBytes: maxBytes)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    private func read(server: ContentServer, depot: UInt32, sha: Data, key: Data,
                      enough: (Data) throws -> Bool, maxBytes: Int) throws -> (plaintext: Data, bytesRead: Int) {
        var bytesRead = 0, retryable = true
        do {
            try Task.checkCancellation()
            guard maxBytes > 0 else { return (Data(), 0) }
            guard !server.vhost.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw SteamError.malformed("peek host") }
            var hints = addrinfo(), addresses: UnsafeMutablePointer<addrinfo>?
            hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_protocol = IPPROTO_TCP
            guard getaddrinfo(server.host, String(port), &hints, &addresses) == 0, let addresses else { throw SteamError.transport }
            defer { freeaddrinfo(addresses) }
            var address: UnsafeMutablePointer<addrinfo>? = addresses
            var socketFD: Int32 = -1
            while let current = address {
                try Task.checkCancellation()
                let a = current.pointee
                let fd = socket(a.ai_family, a.ai_socktype, a.ai_protocol)
                if fd >= 0 {
                    var buffer: Int32 = 16384, one: Int32 = 1
                    do {
                        guard setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buffer, socklen_t(MemoryLayout<Int32>.size)) == 0,
                              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0,
                              fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw SteamError.transport }
                        if connect(fd, a.ai_addr, a.ai_addrlen) != 0 {
                            guard errno == EINPROGRESS else { throw SteamError.transport }
                            try wait(fd, events: Int16(POLLOUT))
                            var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
                            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw SteamError.transport }
                        }
                        socketFD = fd; break
                    } catch {
                        close(fd)
                        if error is CancellationError { throw error }
                    }
                }
                address = a.ai_next
            }
            guard socketFD >= 0 else { throw SteamError.transport }
            defer { close(socketFD) }
            let request = Data("GET /depot/\(depot)/chunk/\(sha.hex) HTTP/1.1\r\nHost: \(server.vhost)\r\nConnection: close\r\n\r\n".utf8)
            var sent = 0
            while sent < request.count {
                try wait(socketFD, events: Int16(POLLOUT))
                let n = request.withUnsafeBytes { send(socketFD, $0.baseAddress!.advanced(by: sent), request.count - sent, 0) }
                if n < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard n > 0 else { throw SteamError.transport }; sent += n
            }
            var parser = PeekHTTPBody(), stream = ChunkStream(key: key)
            while bytesRead < maxBytes {
                try wait(socketFD, events: Int16(POLLIN))
                var data = Data(count: min(4096, maxBytes - bytesRead))
                let n = data.withUnsafeMutableBytes { recv(socketFD, $0.baseAddress, $0.count, 0) }
                if n < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard n >= 0 else { throw SteamError.transport }
                if n == 0 {
                    guard parser.complete else { throw SteamError.malformed("truncated HTTP body") }
                    break
                }
                bytesRead += n; data.count = n
                let body: Data
                do { body = try parser.append(data) }
                catch { retryable = parser.non200; throw error }
                retryable = false
                _ = try stream.append(body)
                if try enough(stream.plaintext) { return (stream.plaintext, bytesRead) }
                if parser.complete {
                    _ = try stream.finish()
                    _ = try enough(stream.plaintext)
                    break
                }
            }
            return (stream.plaintext, bytesRead)
        } catch {
            throw ChunkPeekFailure(underlying: error, bytesRead: bytesRead, retryable: retryable)
        }
    }
    private func wait(_ fd: Int32, events: Int16) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw SteamError.transport }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(100, max(1, remaining * 1000))))
            if result > 0 { return }
            if result < 0 && errno != EINTR { throw SteamError.transport }
        }
    }
}

struct PeekHTTPBody {
    private var pending = Data()
    private var headers = false, chunked = false, remaining = 0, chunkRemaining: Int?
    private var chunkCRLF = false, trailers = false
    private(set) var complete = false, non200 = false
    mutating func append(_ data: Data) throws -> Data {
        pending.append(data)
        var output = Data()
        if !headers {
            guard let end = pending.range(of: Data("\r\n\r\n".utf8)) else {
                guard pending.count <= 32768 else { throw SteamError.malformed("HTTP header limit") }; return output
            }
            guard end.upperBound <= 32768, let text = String(data: pending[..<end.lowerBound], encoding: .utf8) else { throw SteamError.malformed("HTTP headers") }
            let lines = text.components(separatedBy: "\r\n")
            let status = lines[0].split(separator: " ", omittingEmptySubsequences: true)
            guard status.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(String(status[0])), status[1].count == 3, let code = Int(status[1]) else { throw SteamError.malformed("HTTP status") }
            guard code == 200 else { non200 = true; throw SteamError.malformed("HTTP status \(code)") }
            var fields: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { throw SteamError.malformed("HTTP header") }
                let name = String(line[..<colon]).lowercased()
                guard !name.isEmpty, !name.contains(where: { $0.isWhitespace }), fields[name] == nil else { throw SteamError.malformed("HTTP duplicate or invalid header") }
                fields[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            if let encoding = fields["transfer-encoding"] {
                guard encoding.lowercased() == "chunked", fields["content-length"] == nil else { throw SteamError.malformed("HTTP transfer encoding") }
                chunked = true
            } else {
                guard let length = fields["content-length"], !length.isEmpty, length.allSatisfy({ $0.isASCII && $0.isNumber }), let count = Int(length) else { throw SteamError.malformed("HTTP content length") }
                remaining = count
            }
            headers = true; pending = Data(pending[end.upperBound...])
        }
        if !chunked {
            let count = min(remaining, pending.count)
            output.append(pending.prefix(count)); pending = Data(pending.dropFirst(count)); remaining -= count
            complete = remaining == 0; return output
        }
        while !complete {
            if chunkCRLF {
                guard pending.count >= 2 else { break }
                guard pending.prefix(2) == Data([13, 10]) else { throw SteamError.malformed("HTTP chunk terminator") }
                pending = Data(pending.dropFirst(2)); chunkCRLF = false
            }
            if trailers {
                guard let line = pending.range(of: Data([13, 10])) else {
                    guard pending.count <= 32768 else { throw SteamError.malformed("HTTP trailer limit") }; break
                }
                complete = line.lowerBound == 0
                pending = Data(pending[line.upperBound...]); continue
            }
            if chunkRemaining == nil {
                guard let end = pending.range(of: Data([13, 10])) else {
                    guard pending.count <= 1024 else { throw SteamError.malformed("HTTP chunk line limit") }; break
                }
                guard end.lowerBound <= 1024, let line = String(data: pending[..<end.lowerBound], encoding: .utf8),
                      let sizeText = line.split(separator: ";", omittingEmptySubsequences: false).first,
                      !sizeText.isEmpty, sizeText.allSatisfy({ $0.isHexDigit }), let size = Int(sizeText, radix: 16) else { throw SteamError.malformed("HTTP chunk size") }
                pending = Data(pending[end.upperBound...]); chunkRemaining = size
                if size == 0 { trailers = true; continue }
            }
            let count = min(chunkRemaining!, pending.count)
            output.append(pending.prefix(count)); pending = Data(pending.dropFirst(count)); chunkRemaining! -= count
            if chunkRemaining == 0 { chunkRemaining = nil; chunkCRLF = true }
            if count == 0 { break }
        }
        return output
    }
}
