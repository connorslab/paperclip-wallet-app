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
    private func pairingText(_ changes: [String: Any] = [:]) throws -> String {
        var value: [String: Any] = ["kind":"paperclip-jars-v1", "scope":"jars_manage_v1", "endpoint":"https://host.example.invalid", "wallet":"fixture.jmdat",
                                  "token":"pj1_" + String(repeating: "a", count: 64), "expires":4_000_000_000, "certificate_sha256":""]
        value.merge(changes) { _, new in new }
        return "paperclip-jars:" + (try JSONSerialization.data(withJSONObject: value)).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    func testPairingRejectsUnsafeEndpointsScopeAndExpiry() throws {
        for changes: [String: Any] in [["endpoint":"http://host.local"], ["endpoint":"https://user:secret@host.local"], ["scope":"all"], ["expires":1], ["wallet":"../other"], ["token":"main-wallet-token"], ["certificate_sha256":"invalid"]] {
            XCTAssertThrowsError(try JoinBlaketPairing(text: pairingText(changes)))
        }
        let pair = try JoinBlaketPairing(text: pairingText())
        XCTAssertEqual(pair.description, "Jars pairing (redacted)")
        XCTAssertFalse(String(reflecting: pair).contains(String(repeating: "a", count: 64)))
    }
    func testPairedTransportUsesOnlyScopedProxyAndNeverReplays() async throws {
        let pair = try JoinBlaketPairing(text: pairingText())
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [JamStub.self]
        let c = try JoinBlaketClient(connection: pair.connection, configuration: configuration, pairing: pair)
        JamStub.reply = "{\"session\":true,\"wallet_name\":\"fixture.jmdat\",\"maker_running\":false,\"coinjoin_in_process\":false,\"rescanning\":false}"
        _ = try await c.status(pair.authorization())
        XCTAssertEqual(JamStub.requests.count, 1)
        XCTAssertEqual(JamStub.requests[0].url?.path, "/api/v1/paired-jars/request")
        XCTAssertEqual(JamStub.requests[0].httpMethod, "POST")
        let fields = try JSONSerialization.jsonObject(with: JamStub.bodies[0]) as! [String: Any]
        XCTAssertEqual(fields["operation"] as? String, "status")
        XCTAssertEqual(fields["wallet"] as? String, "fixture.jmdat")
        XCTAssertNil(fields["token"]); XCTAssertNil(fields["password"])
        JamStub.requests = []; JamStub.failure = .timedOut
        do { _ = try await c.status(pair.authorization()); XCTFail("Must surface timeout") } catch {}
        XCTAssertEqual(JamStub.requests.count, 1)
        JamStub.requests = []
        do { _ = try await c.unlock(wallet: pair.wallet, password: "synthetic"); XCTFail("No paired unlock") } catch {}
        do { _ = try await c.status(JoinBlaketAuthorization(wallet: "other.jmdat", token: "synthetic")); XCTFail("No other wallet") } catch {}
        XCTAssertTrue(JamStub.requests.isEmpty)
    }
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
    func testRelativeMakerFeesUseExactFractionsAndPairingPreservesMode() async throws {
        let auth = try JoinBlaketAuthorization(wallet: "fixture.jmdat", token: "synthetic-token")
        JamStub.route = { request in
            (200, request.url!.path == "/api/v1/session" ? "{\"session\":true,\"wallet_name\":\"fixture.jmdat\",\"maker_running\":false,\"coinjoin_in_process\":false,\"rescanning\":false}" : "{}")
        }
        let c = try client()
        for rate in JoinBlaketMakerFee.rates {
            try await c.startMaker(minimumSat: 100000, feeSat: 0, authorization: auth, relativeFee: rate)
            let body = try JSONSerialization.jsonObject(with: JamStub.bodies.last!) as! [String:String]
            XCTAssertEqual(body["cjfee_r"], rate); XCTAssertEqual(body["cjfee_a"], "0"); XCTAssertEqual(body["ordertype"], "sw0reloffer")
        }
        JamStub.requests = []
        do { try await c.startMaker(minimumSat: 100000, feeSat: 123, authorization: auth); XCTFail("Off-grid fee") } catch {}
        do { try await c.startMaker(minimumSat: 100000, feeSat: 100, authorization: auth, relativeFee: "0.00005"); XCTFail("Mixed fee modes") } catch {}
        XCTAssertTrue(JamStub.requests.isEmpty)
        XCTAssertEqual(JoinBlaketMakerFee.label("0.00005"), "0.005%")
        let pair = try JoinBlaketPairing(text: pairingText())
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [JamStub.self]
        let paired = try JoinBlaketClient(connection: pair.connection, configuration: configuration, pairing: pair)
        JamStub.reply = "{\"session\":true,\"wallet_name\":\"fixture.jmdat\",\"maker_running\":false,\"coinjoin_in_process\":false,\"rescanning\":false}"
        JamStub.route = nil
        try await paired.startMaker(minimumSat: 100000, feeSat: 0, authorization: pair.authorization(), relativeFee: "0.00005")
        let fields = try JSONSerialization.jsonObject(with: JamStub.bodies.last!) as! [String: Any]
        XCTAssertEqual(fields["operation"] as? String, "start_maker")
        XCTAssertEqual(fields["relative_fee"] as? String, "0.00005")
        XCTAssertEqual(fields["minimum_sat"] as? Int, 100000)
        XCTAssertNil(fields["fee_sat"])
        XCTAssertTrue(JamStub.requests.allSatisfy { $0.url?.path == "/api/v1/paired-jars/request" })
        JamStub.requests = []
        do { _ = try await paired.discardPayment(id: String(repeating: "a", count: 64), authorization: pair.authorization()); XCTFail("Management pairing cannot discard") } catch {}
        XCTAssertTrue(JamStub.requests.isEmpty)
    }
    func testDiscardRejectsSubmittedPaymentsAndDoesNotRetryLostResponse() async throws {
        let auth = try JoinBlaketAuthorization(wallet: "fixture.jmdat", token: "synthetic-token"), id = String(repeating: "a", count: 64)
        let fixture = Bundle.module.url(forResource: "jam-recovery", withExtension: "json", subdirectory: "Fixtures")!
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [[String:Any]]
        var row = cases[0]["payment"] as! [String:Any]; row["id"] = id
        var state = "prepared", lost = false
        JamStub.route = { request in
            if request.url!.path == "/api/v1/session" { return (200, "{\"session\":true,\"wallet_name\":\"fixture.jmdat\",\"maker_running\":false,\"coinjoin_in_process\":false,\"rescanning\":false}") }
            row["state"] = request.httpMethod == "POST" ? "cancelled" : state
            return (lost && request.httpMethod == "POST" ? 504 : 200, String(decoding: try! JSONSerialization.data(withJSONObject: row), as: UTF8.self))
        }
        let c = try client()
        let cancelled = try await c.discardPayment(id: id, authorization: auth); XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertEqual(JamStub.requests.filter { $0.httpMethod == "POST" }.count, 1)
        for next in ["submitting","unknown","submitted"] {
            state = next; JamStub.requests = []
            do { _ = try await c.discardPayment(id: id, authorization: auth); XCTFail("Must retain uncertain submission") } catch {}
            XCTAssertFalse(JamStub.requests.contains { $0.httpMethod == "POST" })
        }
        state = "prepared"; lost = true; JamStub.requests = []
        do { _ = try await c.discardPayment(id: id, authorization: auth); XCTFail("Lost reply") } catch {}
        XCTAssertEqual(JamStub.requests.filter { $0.httpMethod == "POST" }.count, 1)
    }
    func testMarketSummaryRejectsWrongAmountAndExpires() throws {
        let now = Int64(Date().timeIntervalSince1970)
        let data = try JSONSerialization.data(withJSONObject:["amount_sat":100000,"fetched_at":now,"book_updated_at":now,"status":"fresh","maker_count":2,"median_fee_sat":"75.5"])
        let value = try JSONDecoder().decode(JoinBlaketMarket.self, from: data)
        try value.validate(amount:100000, now:now)
        XCTAssertThrowsError(try value.validate(amount:200000, now:now))
        XCTAssertTrue(value.summary(now:Date(timeIntervalSince1970:Double(now+121))).contains("stale"))
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
