import XCTest
@testable import PaperclipMobile

private final class LNDProtocol: URLProtocol {
    static var response: (URLRequest) -> (Int, String) = { _ in (500, "") }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, body) = Self.response(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        // Deliberately keep the stream open. The client must return on IN_FLIGHT.
    }
    override func stopLoading() {}
}

final class LNDStreamTests: XCTestCase {
    let invoiceHash = String(repeating: "ab", count: 32)
    func node() throws -> LightningNode {
        var connection = LightningConnection(); connection.implementation = .lnd
        connection.endpoint = "https://lnd.example"; connection.credential = "abcd"
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [LNDProtocol.self]
        return try LightningNode(connection: connection, configuration: config)
    }
    func testSendUsesRouterAndReturnsWhileStreamRemainsOpen() async throws {
        let hash = invoiceHash
        LNDProtocol.response = { request in
            XCTAssertEqual(request.url?.path, "/v2/router/send")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Grpc-Metadata-macaroon"), "abcd")
            // URLSession may move the body into a stream for URLProtocol.
            var body = request.httpBody
            if body == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 4096)
                let count = stream.read(&bytes, maxLength: bytes.count); if count > 0 { body = Data(bytes.prefix(count)) }
            }
            let fields = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any]
            XCTAssertEqual(fields?["fee_limit_sat"] as? String, "100")
            XCTAssertEqual(fields?["cancelable"] as? Bool, false)
            XCTAssertEqual(fields?["no_inflight_updates"] as? Bool, false)
            return (200, "{\"result\":{\"payment_hash\":\"\(hash)\",\"status\":\"IN_FLIGHT\"}}\n")
        }
        let start = Date()
        let response = try await node().pay("lnbc-fixture", maximumFee: 100)
        XCTAssertNil(try LNDStreamResponse.terminalState(response, hash: hash))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
    func testTrackExactHashAndNotFound() async throws {
        LNDProtocol.response = { request in
            XCTAssertTrue(request.url!.path.hasPrefix("/v2/router/track/"))
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "false")
            return (404, "{\"code\":5,\"message\":\"payment not initiated\"}\n")
        }
        do { _ = try await node().trackPayment(hash: invoiceHash); XCTFail("missing error") }
        catch let error as LNDStreamError { XCTAssertEqual(error.code, 5); XCTAssertFalse(error.definitelyRejected) }
    }
    func testUnsupportedMethodIsRejectedWithoutWaitingForBody() async throws {
        LNDProtocol.response = { _ in (404, "") }
        do { _ = try await node().pay("lnbc-fixture", maximumFee: 100); XCTFail("missing error") }
        catch let error as LNDStreamError { XCTAssertEqual(error.code, 12); XCTAssertTrue(error.definitelyRejected) }
    }
    func testExistingPaymentIsNeverClassifiedAsRejected() async throws {
        LNDProtocol.response = { _ in (409, "{\"error\":{\"code\":6,\"message\":\"already paid\"}}\n") }
        do { _ = try await node().pay("lnbc-fixture", maximumFee: 100); XCTFail("missing error") }
        catch let error as LNDStreamError { XCTAssertFalse(error.definitelyRejected) }
    }
    func testTerminalAndUncertainResponses() throws {
        for (status, result) in [("SUCCEEDED", "succeeded"), ("FAILED", "failed")] {
            let data = try LNDStreamResponse.decode(Data("{\"result\":{\"payment_hash\":\"\(invoiceHash)\",\"status\":\"\(status)\"}}".utf8))
            XCTAssertEqual(try LNDStreamResponse.terminalState(data, hash: invoiceHash), result)
            XCTAssertThrowsError(try LNDStreamResponse.terminalState(data, hash: String(repeating: "cd", count: 32)))
        }
        XCTAssertThrowsError(try LNDStreamResponse.decode(Data("{}".utf8)))
        XCTAssertFalse(LNDStreamError(code: 6, message: "already exists").definitelyRejected)
        XCTAssertFalse(LNDStreamError(code: 4, message: "deadline exceeded").definitelyRejected)
        XCTAssertTrue(LNDStreamError(code: 12, message: "unimplemented").definitelyRejected)
    }
}
