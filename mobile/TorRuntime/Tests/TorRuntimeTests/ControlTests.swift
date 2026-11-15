import XCTest
import Foundation
import Darwin
import TorRuntime

final class ControlTests: XCTestCase {
    private func server(connections: Int = 1, _ body: @escaping (Int32) -> Void) throws -> UInt16 {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0); XCTAssertEqual(listen(listener, 1), 0)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &size) }
        }
        let port = UInt16(bigEndian: address.sin_port)
        DispatchQueue.global().async {
            defer { close(listener) }
            for _ in 0..<connections {
                let client = accept(listener, nil, nil)
                var timeout = timeval(tv_sec: 5, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                body(client)
                close(client)
            }
        }
        return port
    }
    private static func line(_ fd: Int32) -> String {
        var bytes = [UInt8](), byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            bytes.append(byte)
            if byte == 10 { break }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
    private static func send(_ fd: Int32, _ value: String) {
        _ = value.withCString { Darwin.write(fd, $0, strlen($0)) }
    }
    func testPipelinedRepliesKeepRequestOrder() throws {
        let port = try server { fd in
            XCTAssertEqual(Self.line(fd), "GETINFO version\r\n")
            XCTAssertEqual(Self.line(fd), "GETINFO uptime\r\n")
            Self.send(fd, "250-version=0.4.9.13\r\n250 OK\r\n250-uptime=42\r\n250 OK\r\n")
        }
        let control = TorController(socketHost: "127.0.0.1", port: port)
        let first = expectation(description: "version"), second = expectation(description: "uptime")
        control.getInfoForKeys(["version"]) { values in XCTAssertEqual(values, ["0.4.9.13"]); first.fulfill() }
        control.getInfoForKeys(["uptime"]) { values in XCTAssertEqual(values, ["42"]); second.fulfill() }
        wait(for: [first, second], timeout: 5)
        withExtendedLifetime(control) {}
    }
    func testFragmentedAuthenticationAndReadinessReplies() throws {
        let port = try server { fd in
            XCTAssertTrue(Self.line(fd).hasPrefix("AUTHENTICATE "))
            Self.send(fd, "250 O"); usleep(10000); Self.send(fd, "K\r\n")
            XCTAssertTrue(Self.line(fd).hasPrefix("GETINFO "))
            for line in ["250-status/circuit-established=1\r\n", "250-net/listeners/socks=\"127.0.0.1:9050\"\r\n", "250-status/bootstrap-phase=NOTICE BOOTSTRAP PROGRESS=100 TAG=done SUMMARY=\"Done\"\r\n", "250 OK\r\n"] {
                Self.send(fd, line); usleep(10000)
            }
        }
        let control = TorController(socketHost: "127.0.0.1", port: port)
        let ready = expectation(description: "ready")
        control.authenticate(with: Data(repeating: 1, count: 32)) { success, error in
            XCTAssertTrue(success); XCTAssertNil(error)
            control.getInfoForKeys(["status/circuit-established", "net/listeners/socks", "status/bootstrap-phase"]) { values in
                XCTAssertEqual(values.count, 3)
                XCTAssertEqual(values.first, "1")
                XCTAssertTrue(values.last?.contains("PROGRESS=100") == true)
                ready.fulfill()
            }
        }
        wait(for: [ready], timeout: 5)
    }
    func testClosedPeerClearsConnectionState() throws {
        let port = try server { fd in _ = Self.line(fd) }
        let control = TorController(socketHost: "127.0.0.1", port: port)
        control.getInfoForKeys(["version"]) { _ in }
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !control.isConnected }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 3), .completed)
    }
    func testAuthenticationFailureCanRetryOnFreshControlConnection() throws {
        var attempt = 0
        let port = try server(connections: 2) { fd in
            attempt += 1
            XCTAssertTrue(Self.line(fd).hasPrefix("AUTHENTICATE "))
            Self.send(fd, attempt == 1 ? "515 Authentication failed\r\n" : "250 OK\r\n")
        }
        let first = TorController(socketHost: "127.0.0.1", port: port)
        let rejected = expectation(description: "rejected")
        first.authenticate(with: Data(repeating: 0, count: 32)) { success, error in
            XCTAssertFalse(success); XCTAssertNotNil(error); rejected.fulfill()
        }
        wait(for: [rejected], timeout: 5)
        first.close()
        let retry = TorController(socketHost: "127.0.0.1", port: port)
        let accepted = expectation(description: "retry accepted")
        retry.authenticate(with: Data(repeating: 1, count: 32)) { success, error in
            XCTAssertTrue(success); XCTAssertNil(error); accepted.fulfill()
        }
        wait(for: [accepted], timeout: 5)
    }
    func testErrorReplyDoesNotConsumeNextRequest() throws {
        let port = try server { fd in
            _ = Self.line(fd); _ = Self.line(fd)
            Self.send(fd, "552 Unrecognized key\r\n250-version=0.4.9.13\r\n250 OK\r\n")
        }
        let control = TorController(socketHost: "127.0.0.1", port: port)
        let invalid = expectation(description: "invalid"), valid = expectation(description: "valid")
        control.getInfoForKeys(["not-a-key"]) { values in XCTAssertTrue(values.isEmpty); invalid.fulfill() }
        control.getInfoForKeys(["version"]) { values in XCTAssertEqual(values, ["0.4.9.13"]); valid.fulfill() }
        wait(for: [invalid, valid], timeout: 5)
    }

}
