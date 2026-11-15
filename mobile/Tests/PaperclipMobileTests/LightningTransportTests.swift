import XCTest
@testable import PaperclipMobile

private final class NodeTransportStub: URLProtocol {
    enum Reply { case failed(URLError.Code), response(Int, String) }
    private static let lock = NSLock()
    private static var replies: [Reply] = []
    private static var count = 0
    static var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func reset(_ values: [Reply]) { lock.lock(); defer { lock.unlock() }; replies = values; count = 0 }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        let reply = Self.replies.isEmpty ? Reply.failed(.badServerResponse) : Self.replies.removeFirst()
        Self.lock.unlock()
        switch reply {
        case .failed(let code): client?.urlProtocol(self, didFailWithError: URLError(code))
        case .response(let status, let body):
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

final class LightningTransportTests: XCTestCase {
    private func node(_ implementation: LightningImplementation = .cln) throws -> LightningNode {
        var connection = LightningConnection()
        connection.endpoint = "https://node.example.invalid"
        connection.credential = "00"
        connection.implementation = implementation
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NodeTransportStub.self]
        return try LightningNode(connection: connection, configuration: configuration)
    }
    func testReadOnlyCLNPostAndLNDGetRetryTransientDisconnectOnce() async throws {
        for implementation in LightningImplementation.allCases {
            NodeTransportStub.reset([.failed(.networkConnectionLost), .response(200, "{}")])
            _ = try await node(implementation).info()
            XCTAssertEqual(NodeTransportStub.requests, 2)
        }
    }
    func testReadRetryIsBounded() async throws {
        NodeTransportStub.reset([.failed(.timedOut), .failed(.timedOut), .response(200, "{}")])
        do { _ = try await node().info(); XCTFail("Must stop after one retry") } catch {}
        XCTAssertEqual(NodeTransportStub.requests, 2)
    }
    func testCreationAndPaymentAreNeverRetried() async throws {
        NodeTransportStub.reset([.failed(.networkConnectionLost), .response(200, "{}")])
        do { _ = try await node().invoice(amount: 10); XCTFail("Must not replay invoice creation") } catch {}
        XCTAssertEqual(NodeTransportStub.requests, 1)
        NodeTransportStub.reset([.failed(.timedOut), .response(200, "{}")])
        do { _ = try await node().pay("synthetic-invoice", maximumFee: 1); XCTFail("Must not replay payment") } catch {}
        XCTAssertEqual(NodeTransportStub.requests, 1)
    }
    func testAuthorizationTLSAndCancellationNeverRetry() async throws {
        NodeTransportStub.reset([.response(401, "{}"), .response(200, "{}")])
        do { _ = try await node().info(); XCTFail("Must reject credential failure") } catch {}
        XCTAssertEqual(NodeTransportStub.requests, 1)
        for code in [URLError.Code.cancelled, .serverCertificateUntrusted, .secureConnectionFailed] {
            NodeTransportStub.reset([.failed(code), .response(200, "{}")])
            do { _ = try await node().info(); XCTFail("Must not retry trust or cancellation") } catch {}
            XCTAssertEqual(NodeTransportStub.requests, 1)
        }
    }
    func testCancellationDuringBackoffStopsRetry() async throws {
        NodeTransportStub.reset([.failed(.networkConnectionLost), .response(200, "{}")])
        let client = try node()
        let task = Task { try await client.info() }
        for _ in 0..<50 {
            if NodeTransportStub.requests == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled operation must stop") } catch {}
        XCTAssertEqual(NodeTransportStub.requests, 1)
    }
}
