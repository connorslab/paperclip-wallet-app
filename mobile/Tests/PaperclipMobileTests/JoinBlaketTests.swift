import XCTest
@testable import PaperclipMobile

private final class JamStub: URLProtocol {
    static var reply = "{}"
    static var status = 200
    static var failure: URLError.Code?
    static var requests: [URLRequest] = []
    static var bodies: [Data] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        Self.bodies.append(body)
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure)); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class JoinBlaketTests: XCTestCase {
    override func setUp() { JamStub.reply = "{}"; JamStub.status = 200; JamStub.failure = nil; JamStub.requests = []; JamStub.bodies = [] }
    private func client() throws -> JoinBlaketClient {
        var connection = JoinBlaketConnection(); connection.endpoint = "https://jam.example.invalid"
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [JamStub.self]
        return try JoinBlaketClient(connection: connection, configuration: configuration)
    }
    func testUnlockPassphraseIsExplicitAndNeverPutInURL() async throws {
        JamStub.reply = "{\"walletname\":\"wallet.jmdat\",\"token\":\"synthetic-token\"}"
        _ = try await client().unlock(wallet: "wallet.jmdat", password: "synthetic-password", passphrase: "synthetic-passphrase")
        let body = try JSONSerialization.jsonObject(with: JamStub.bodies[0]) as! [String: String]
        XCTAssertEqual(body["bip39_passphrase"], "synthetic-passphrase")
        XCTAssertEqual(body["password"], "synthetic-password")
        XCTAssertNil(JamStub.requests[0].url?.query)
        _ = try await client().unlock(wallet: "wallet.jmdat", password: "synthetic-password")
        let empty = try JSONSerialization.jsonObject(with: JamStub.bodies[1]) as! [String: String]
        XCTAssertNil(empty["bip39_passphrase"])
    }
    func testReceiveUsesSelectedJarAndNeverRetriesMutation() async throws {
        let auth = try JoinBlaketAuthorization(wallet: "wallet.jmdat", token: "synthetic-token")
        JamStub.reply = "{\"address\":\"synthetic-address\"}"
        let address = try await client().receiveAddress(jar: 3, authorization: auth)
        XCTAssertEqual(address, "synthetic-address")
        XCTAssertEqual(JamStub.requests.last?.url?.path, "/api/v1/wallet/wallet.jmdat/address/new/3")
        JamStub.requests = []; JamStub.failure = .timedOut
        do { _ = try await client().receiveAddress(jar: 3, authorization: auth); XCTFail("Must report uncertainty") } catch {}
        XCTAssertEqual(JamStub.requests.count, 1)
    }
    func testWrongWalletAndExpiredAuthorizationStopRefresh() async throws {
        let auth = try JoinBlaketAuthorization(wallet: "expected.jmdat", token: "synthetic-token")
        JamStub.reply = "{\"session\":true,\"maker_running\":false,\"coinjoin_in_process\":false,\"wallet_name\":\"different.jmdat\",\"rescanning\":false}"
        do { _ = try await client().coins(auth); XCTFail("Must reject other wallet") } catch {}
        XCTAssertEqual(JamStub.requests.count, 1)
        JamStub.requests = []; JamStub.status = 401
        do { _ = try await client().status(auth); XCTFail("Must reject expired token") } catch {}
        XCTAssertEqual(JamStub.requests.count, 1)
    }
    func testWalletPathsCannotEscapeAndTokenIsRedacted() async throws {
        let auth = try JoinBlaketAuthorization(wallet: "../other", token: "synthetic-secret")
        XCTAssertFalse(String(describing: auth).contains("synthetic-secret"))
        do { _ = try await client().receiveAddress(jar: 0, authorization: auth); XCTFail("Must reject path traversal") } catch {}
        XCTAssertTrue(JamStub.requests.isEmpty)
        do { _ = try await client().receiveAddress(jar: 5, authorization: auth); XCTFail("Must reject unknown jar") } catch {}
        XCTAssertTrue(JamStub.requests.isEmpty)
    }
    func testTransportPolicyRejectsClearnetHTTPAndUnroutedOnion() {
        for endpoint in ["http://start.local:28183", "https://example.onion"] {
            var c = JoinBlaketConnection(); c.endpoint = endpoint
            XCTAssertThrowsError(try c.validate())
        }
    }
}
