import XCTest
@testable import PaperclipMobile

private final class JamStub: URLProtocol {
    static var reply = "{}"
    static var status = 200
    static var failure: URLError.Code?
    static var requests: [URLRequest] = []
    static var bodies: [Data] = []
    static var route: ((URLRequest) -> (Int, String))?
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
        let reply = Self.route?(request) ?? (Self.status, Self.reply)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class JoinBlaketTests: XCTestCase {
    func testRecoveryMatchesSharedCases() throws {
        let url = Bundle.module.url(forResource: "jam-recovery", withExtension: "json", subdirectory: "Fixtures")!
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        for item in cases {
            let data = try JSONSerialization.data(withJSONObject: item["payment"]!)
            do {
                let payment = try JSONDecoder().decode(JoinBlaketPayment.self, from: data)
                try payment.validate(wallet: "fixture.jmdat")
                XCTAssertEqual(item["valid"] as? Bool, true, item["name"] as! String)
                XCTAssertFalse(payment.state.label.lowercased().contains("successful"))
            } catch { XCTAssertEqual(item["valid"] as? Bool, false, item["name"] as! String) }
        }
    }
    func testRecoveryChecksAreReadOnlyAndFailuresDoNotReplay() async throws {
        let auth = try JoinBlaketAuthorization(wallet: "fixture.jmdat", token: "synthetic-token")
        let url = Bundle.module.url(forResource: "jam-recovery", withExtension: "json", subdirectory: "Fixtures")!
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        let record = try JSONSerialization.data(withJSONObject: cases[3]["payment"]!)
        let body = String(decoding: record, as: UTF8.self)
        var code = 200
        JamStub.route = { request in
            if request.url!.path == "/api/v1/session" { return (200, "{\"session\":true,\"wallet_name\":\"fixture.jmdat\",\"maker_running\":false,\"coinjoin_in_process\":false,\"rescanning\":false}") }
            return (code, request.url!.path.hasSuffix("/payments") ? "{\"payments\":[" + body + "]}" : body)
        }
        let c = try client()
        let rows = try await c.payments(auth)
        XCTAssertEqual(rows.count, 1)
        let checked = try await c.checkPayment(id: rows[0].id, authorization: auth)
        XCTAssertEqual(checked.state, .unknown)
        XCTAssertEqual(JamStub.requests.count, 4)
        XCTAssertTrue(JamStub.requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.query == nil })
        code = 504; JamStub.requests = []
        do { _ = try await c.checkPayment(id: rows[0].id, authorization: auth); XCTFail("Must surface timeout") } catch {}
        XCTAssertEqual(JamStub.requests.count, 2)
        JamStub.requests = []
        do { _ = try await c.checkPayment(id: "../commit", authorization: auth); XCTFail("Must reject bad id") } catch {}
        XCTAssertTrue(JamStub.requests.isEmpty)
        code = 404
        do { _ = try await c.payments(auth); XCTFail("Missing companion is not empty history") } catch {}
    }
    func testMakerReadinessMatchesSharedCases() throws {
        struct Case: Decodable {
            let name: String, minimum: String, fee: String
            let jars: [JoinBlaketJar]
            let session: JoinBlaketSession?
            let needsRefresh: Bool
            let expected: [String: Bool]
        }
        let url = Bundle.module.url(forResource: "maker-readiness", withExtension: "json", subdirectory: "Fixtures")!
        for item in try JSONDecoder().decode([Case].self, from: Data(contentsOf: url)) {
            let value = JoinBlaketMakerReadiness(minimum: item.minimum, fee: item.fee, jars: item.jars, session: item.session, needsRefresh: item.needsRefresh)
            XCTAssertEqual(["terms": value.terms, "funds": value.funds, "bond": value.bond, "server": value.server, "fresh": value.fresh, "canStart": value.canStart], item.expected, item.name)
        }
    }
    override func setUp() { JamStub.reply = "{}"; JamStub.status = 200; JamStub.failure = nil; JamStub.requests = []; JamStub.bodies = []; JamStub.route = nil }
    func testBondMonthHasStrictUtcFutureBoundary() throws {
        let now = ISO8601DateFormatter().date(from: "2030-05-01T00:00:00Z")!
        for month in ["2030-05", "2030-04", "2030-00", "2030-13", "2030-6", "2100-01", "2019-12", "2031-01/other", "２０３１-01"] {
            XCTAssertThrowsError(try JoinBlaketBond.validate(month: month, now: now), month)
        }
        for month in ["2030-06", "2032-02", "2099-12"] { try JoinBlaketBond.validate(month: month, now: now) }
    }
    func testBondRegistersOnlyReviewedMonthAndDoesNotReplay() async throws {
        let auth = try JoinBlaketAuthorization(wallet: "wallet.jmdat", token: "synthetic-token")
        let state = "{\"session\":true,\"maker_running\":false,\"coinjoin_in_process\":false,\"wallet_name\":\"wallet.jmdat\",\"rescanning\":false}"
        var failAddress = false
        JamStub.route = { request in
            if request.url?.path == "/api/v1/session" { return (200, state) }
            return (failAddress ? 504 : 200, "{\"address\":\"bc1qsyntheticbond\"}")
        }
        let address = try await client().bondAddress(month: "2099-12", authorization: auth)
        XCTAssertEqual(address, "bc1qsyntheticbond")
        XCTAssertEqual(JamStub.requests.map { $0.url!.path }, ["/api/v1/session", "/api/v1/wallet/wallet.jmdat/address/timelock/new/2099-12"])
        XCTAssertTrue(JamStub.requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.query == nil })
        JamStub.requests = []; failAddress = true
        do { _ = try await client().bondAddress(month: "2099-12", authorization: auth); XCTFail("Must surface uncertain response") } catch {}
        XCTAssertEqual(JamStub.requests.count, 2, "One status check and one address request; no replay")
        JamStub.requests = []
        do { _ = try await client().bondAddress(month: "2020-01", authorization: auth); XCTFail("Must reject past date") } catch {}
        XCTAssertTrue(JamStub.requests.isEmpty)
        do { _ = try await client().bondAddress(month: "2099-12", authorization: JoinBlaketAuthorization(wallet: "other.jmdat", token: "synthetic-token")); XCTFail("Must reject other wallet") } catch {}
        XCTAssertEqual(JamStub.requests.count, 1)
    }
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
