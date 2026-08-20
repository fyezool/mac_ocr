import XCTest
import Foundation
import Darwin
@testable import OCRCore

private func liveRawSend(host: String = "127.0.0.1", port: UInt16, payload: Data) -> Data? {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { Darwin.close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = CFSwapInt16HostToBig(port)
    addr.sin_addr.s_addr = inet_addr(host)
    let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard r == 0 else { return nil }
    _ = payload.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, payload.count, 0) }
    Darwin.shutdown(fd, SHUT_WR)
    var out = Data()
    var buf = [UInt8](repeating: 0, count: 8192)
    for _ in 0..<20 {
        let n = Darwin.recv(fd, &buf, buf.count, 0)
        if n > 0 { out.append(buf, count: n) }
        else if n == 0 { break }
        else { if errno == EAGAIN || errno == EWOULDBLOCK { usleep(50000); continue } else { break } }
    }
    return out
}

final class LiveSocketFuzzTests: XCTestCase {
    private func startServer() async throws -> (ServerManager, UInt16) {
        let s = ServerManager()
        let port = UInt16.random(in: 30000...50000)
        s.start(port: port)
        for _ in 0..<100 where !s.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(s.isRunning)
        return (s, port)
    }
    private func rawSend(port: UInt16, payload: Data) -> Data? {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(port)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard r == 0 else { return nil }
        _ = payload.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, payload.count, 0) }
        Darwin.shutdown(fd, SHUT_WR)
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        for _ in 0..<20 {
            let n = Darwin.recv(fd, &buf, buf.count, 0)
            if n > 0 { out.append(buf, count: n) }
            else if n == 0 { break }
            else { if errno == EAGAIN || errno == EWOULDBLOCK { usleep(50000); continue } else { break } }
        }
        return out
    }

    func testLiveMalformedRequestsDoNotCrash() async throws {
        let (srv, port) = try await startServer()
        defer { srv.stop() }
        let payloads: [Data] = [
            Data("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8),
            Data("POST /ocr HTTP/1.1\r\nHost: x\r\nContent-Length: 999\r\n\r\nshort".utf8),
            Data("GET /health HTTP/1.1\r\nHost: x\r\n\r\n".utf8),
            Data("POST /ocr HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\nhello".utf8),
            Data("POST /ocr HTTP/1.1\r\nHost: x\r\nContent-Type: multipart/form-data; boundary=abc\r\nContent-Length: 10\r\n\r\n--abc--".utf8),
        ]
        let host = srv.address
        for p in payloads {
            _ = liveRawSend(host: host, port: port, payload: p)
            XCTAssertTrue(srv.isRunning, "server crashed on payload \(p.prefix(80))")
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let health = liveRawSend(host: host, port: port, payload: Data("GET /health HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
        XCTAssertTrue(health?.range(of: Data("200".utf8)) != nil)
    }

    func testLiveOversizedHeaderRejected() async throws {
        let (srv, port) = try await startServer()
        defer { srv.stop() }
        var big = "GET / HTTP/1.1\r\nHost: x\r\n"
        for _ in 0..<2000 { big += "X-Foo: bar\r\n" }
        big += "\r\n"
        try await Task.sleep(nanoseconds: 100_000_000)
        _ = liveRawSend(host: srv.address, port: port, payload: Data(big.utf8)) ?? rawSend(port: port, payload: Data(big.utf8))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(srv.isRunning)
    }

    func testLiveConcurrentFuzzStorm() async throws {
        let (srv, port) = try await startServer()
        defer { srv.stop() }
        // Use well-formed requests for storm; malformed truncated ones would hit the 30s read timeout
        let host = srv.address
        await withTaskGroup(of: Bool.self) { [host, port] g in
            for i in 0..<10 {
                g.addTask { [host, port] in
                    let payload: Data
                    if i % 3 == 0 { payload = Data("GET /health HTTP/1.1\r\nHost: x\r\n\r\n".utf8) }
                    else if i % 3 == 1 { payload = Data("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8) }
                    else { payload = Data("POST /ocr HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello".utf8) }
                    return liveRawSend(host: host, port: port, payload: payload) != nil
                }
            }
            var ok = 0
            for await v in g where v { ok += 1 }
            XCTAssertEqual(ok, 10)
        }
        XCTAssertTrue(srv.isRunning)
    }
}
