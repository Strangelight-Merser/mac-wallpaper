import Foundation
import Darwin
import XCTest
@testable import WESteam

private final class PeekLoopback: @unchecked Sendable {
    let fd: Int32
    let port: UInt16
    let completed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var closed = false
    var peerClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
    init(response: Data, delay: TimeInterval = 0) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        self.fd = fd
        guard fd >= 0 else { throw SteamError.transport }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 1) == 0 else {
            let code = errno
            close(fd)
            if code == EPERM || code == EACCES { throw XCTSkip("Sandbox denies loopback bind/listen (errno \(code))") }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        port = UInt16(bigEndian: address.sin_port)
        DispatchQueue.global().async { [self] in
            defer { completed.signal() }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var request = [UInt8](repeating: 0, count: 4096)
            _ = recv(client, &request, request.count, 0)
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            var sent = 0
            while sent < response.count {
                let n = response.withUnsafeBytes { send(client, $0.baseAddress!.advanced(by: sent), min(4096, response.count - sent), 0) }
                if n <= 0 { lock.lock(); closed = true; lock.unlock(); return }
                sent += n
            }
            var byte: UInt8 = 0
            let n = recv(client, &byte, 1, 0)
            if n <= 0 { lock.lock(); closed = true; lock.unlock() }
        }
    }
    deinit { close(fd) }
}

final class ChunkPeekTests: XCTestCase {
    let server = ContentServer(host: "127.0.0.1", vhost: "fixture")
    func response(_ body: Data, chunked: Bool = false) -> Data {
        if !chunked { return Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body }
        var result = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        for offset in stride(from: 0, to: body.count, by: 113) {
            let bytes = body.subdata(in: offset..<min(offset + 113, body.count))
            result.append(Data("\(String(bytes.count, radix: 16));test=yes\r\n".utf8)); result.append(bytes); result.append(Data([13, 10]))
        }
        result.append(Data("0\r\nX-Test: yes\r\n\r\n".utf8)); return result
    }
    func testLengthAndChunked() async throws {
        let plain = Data((0..<10000).map { UInt8(truncatingIfNeeded: $0) })
        let encrypted = try encrypt(zip(plain, compressed: false))
        for chunked in [false, true] {
            let wire = response(encrypted, chunked: chunked), fixture = try PeekLoopback(response: wire)
            let result = try await ChunkPeek(port: fixture.port).peek(server: server, depot: 1, sha: Data(), key: testKey, enough: { _ in false }, maxBytes: 100000)
            XCTAssertEqual(result.plaintext, plain); XCTAssertEqual(result.bytesRead, wire.count)
        }
    }
    func testEarlyCloseAndBudget() async throws {
        let plain = Data(repeating: 123, count: 1024 * 1024)
        let wire = try response(encrypt(zip(plain, compressed: false)))
        let fixture = try PeekLoopback(response: wire)
        let result = try await ChunkPeek(port: fixture.port).peek(server: server, depot: 1, sha: Data(), key: testKey, enough: { $0.count >= 1024 }, maxBytes: 262144)
        XCTAssertLessThan(result.bytesRead, 16384)
        XCTAssertEqual(result.plaintext, Data(plain.prefix(result.plaintext.count)))
        XCTAssertEqual(fixture.completed.wait(timeout: .now() + 3), .success)
        XCTAssertTrue(fixture.peerClosed)
        let capped = try PeekLoopback(response: wire)
        let partial = try await ChunkPeek(port: capped.port).peek(server: server, depot: 1, sha: Data(), key: testKey, enough: { _ in false }, maxBytes: 2000)
        XCTAssertEqual(partial.bytesRead, 2000)
    }
    func testFailuresTimeoutAndCancellation() async throws {
        for text in ["HTTP/1.1 404 Missing\r\nContent-Length: 0\r\n\r\n", "HTTP/1.1 200 OK\r\n\r\n", "HTTP/1.1 200 OK\r\nContent-Length: bad\r\n\r\n"] {
            let fixture = try PeekLoopback(response: Data(text.utf8))
            do {
                _ = try await ChunkPeek(port: fixture.port).peek(server: server, depot: 1, sha: Data(), key: testKey, enough: { _ in false }, maxBytes: 50000)
                XCTFail("expected HTTP failure")
            } catch let error as ChunkPeekFailure {
                XCTAssertEqual(error.bytesRead, text.utf8.count)
                XCTAssertEqual(error.retryable, text.contains("404"))
            }
        }
        let slow = try PeekLoopback(response: Data(), delay: 0.5)
        do {
            _ = try await ChunkPeek(port: slow.port, timeout: 0.05).peek(server: server, depot: 1, sha: Data(), key: testKey, enough: { _ in false }, maxBytes: 100)
            XCTFail("expected timeout")
        } catch let error as ChunkPeekFailure { XCTAssertEqual(error.bytesRead, 0) }
        let stalled = try PeekLoopback(response: Data(), delay: 0.5)
        let task = Task { try await ChunkPeek(port: stalled.port).peek(server: server, depot: 1, sha: Data(), key: testKey, enough: { _ in false }, maxBytes: 100) }
        try await Task.sleep(for: .milliseconds(30)); task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") }
        catch let error as ChunkPeekFailure { XCTAssertTrue(error.underlying is CancellationError) }
    }
    func testParserSplitsAndInvalidFraming() throws {
        let body = Data("abc".utf8)
        var parser = PeekHTTPBody(), decoded = Data()
        for byte in response(body, chunked: true) { decoded.append(try parser.append(Data([byte]))) }
        XCTAssertEqual(decoded, body); XCTAssertTrue(parser.complete)
        for text in [
            "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\n",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\n",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 1\r\n\r\n",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nZ\r\n",
            String(repeating: "x", count: 32769)
        ] {
            var bad = PeekHTTPBody()
            XCTAssertThrowsError(try bad.append(Data(text.utf8)))
        }
    }
}
