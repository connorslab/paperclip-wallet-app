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
    func testUntrustedPairingExplainsNewCodeWithoutRetry() async throws {
        let pair = try JoinBlaketPairing(text: pairingText())
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [JamStub.self]
        JamStub.requests = []; JamStub.failure = .serverCertificateUntrusted
        defer { JamStub.failure = nil; JamStub.requests = [] }
        let client = try JoinBlaketClient(connection: pair.connection, configuration: configuration, pairing: pair)
        do { _ = try await client.status(pair.authorization()); XCTFail("Untrusted certificate accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("automatic certificate setup")) }
        XCTAssertEqual(JamStub.requests.count, 1)
        JamStub.failure = .timedOut
        do { _ = try await client.status(pair.authorization()); XCTFail("Timeout accepted") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        XCTAssertEqual(JamStub.requests.count, 2, "No automatic retry")
    }

    func testPairedBondInventoryUsesReadOnlyHostRoute() async throws {
        let pair = try JoinBlaketPairing(text: pairingText())
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [JamStub.self]
        let client = try JoinBlaketClient(connection: pair.connection, configuration: configuration, pairing: pair)
        let file = Bundle.module.url(forResource: "jam-bonds", withExtension: "json", subdirectory: "Fixtures")!
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [[String: Any]]
        var operations: [String] = []
        JamStub.route = { request in
            XCTAssertEqual(request.url!.path,"/api/v1/paired-jars/request")
            let fields = try! JSONSerialization.jsonObject(with: JamStub.bodies.last!) as! [String: Any]
            let operation = fields["operation"] as! String; operations.append(operation)
            if operation == "status" { return (200,"{\"session\":true,\"maker_running\":false,\"coinjoin_in_process\":false,\"rescanning\":false,\"wallet_name\":\"fixture.jmdat\"}") }
            XCTAssertEqual(operation,"bonds")
            return (200,String(decoding:try! JSONSerialization.data(withJSONObject:cases[0]["inventory"]!),as:UTF8.self))
        }
        let inventory = try await client.bonds(pair.authorization())
        XCTAssertEqual(inventory.bonds.count,1)
        XCTAssertEqual(operations,["status","bonds"])
    }
    func testBondInventoryMatchesSharedCases() throws {
        let file = Bundle.module.url(forResource: "jam-bonds", withExtension: "json", subdirectory: "Fixtures")!
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [[String: Any]]
        for item in cases {
            let data = try JSONSerialization.data(withJSONObject: item["inventory"]!)
            let result = Result { let value = try JSONDecoder().decode(JoinBlaketBondInventory.self, from: data); try value.validate(wallet: "fixture.jmdat"); return value }
            switch result {
            case .success(let value):
                XCTAssertEqual(item["valid"] as? Bool,true,item["name"] as! String)
                XCTAssertEqual(value.bonds.map { $0.canWithdraw(chainTime: value.chain_time) },item["withdrawable"] as! [Bool])
            case .failure: XCTAssertEqual(item["valid"] as? Bool,false,item["name"] as! String)
            }
        }
    }
    func testSendReviewMatchesSharedCases() throws {
        let draft = try JoinBlaketSendDraft(jar: 0, destination: "bcrt1qsyntheticrecipient", amountSat: 20000, feeRateMillisatVb: 1000, maxFeeSat: 500, id: String(repeating: "a", count: 64))
        let file = Bundle.module.url(forResource: "jam-send-review", withExtension: "json", subdirectory: "Fixtures")!
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [[String: Any]]
        for item in cases {
            let selected = try JoinBlaketSendDraft(jar: draft.jar, destination: draft.destination, amountSat: draft.amountSat, feeRateMillisatVb: draft.feeRateMillisatVb, maxFeeSat: draft.maxFeeSat, coinjoin: item["coinjoin"] as? Bool ?? false, bondLocktime: item["bond_locktime"] as? Int64, bondOutpoint: item["bond_outpoint"] as? String, id: draft.id)
            do {
                let review = try JoinBlaketSendReview(data: JSONSerialization.data(withJSONObject: item["review"]!))
                try review.validate(draft: selected, wallet: "fixture.jmdat", identity: "xbt-regtest:" + String(repeating: "c", count: 64), now: 2000000000)
                XCTAssertEqual(item["valid"] as? Bool, true, item["name"] as! String)
            } catch { XCTAssertEqual(item["valid"] as? Bool, false, item["name"] as! String) }
        }
        XCTAssertThrowsError(try JoinBlaketSendDraft(jar: 0, destination: draft.destination, amountSat: UInt64.max, feeRateMillisatVb: 1000, maxFeeSat: 1))
        for stamp: Int64 in [1,4_099_766_401] {
            XCTAssertThrowsError(try JoinBlaketSendDraft(jar:0,destination:draft.destination,amountSat:20000,feeRateMillisatVb:1000,maxFeeSat:500,bondLocktime:stamp))
        }
        XCTAssertThrowsError(try JoinBlaketSendDraft(jar:0,destination:draft.destination,amountSat:20000,feeRateMillisatVb:1000,maxFeeSat:500,coinjoin:true,bondLocktime:2100000000))
    }
    func testDirectSendBindsReviewAndNeverRepeatsLostCommit() async throws {
        let auth = try JoinBlaketAuthorization(wallet: "fixture.jmdat", token: "synthetic-token")
        let draft = try JoinBlaketSendDraft(jar: 0, destination: "bcrt1qsyntheticrecipient", amountSat: 20000, feeRateMillisatVb: 1000, maxFeeSat: 500, id: String(repeating: "a", count: 64))
        let file = Bundle.module.url(forResource: "jam-send-review", withExtension: "json", subdirectory: "Fixtures")!
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [[String: Any]]
        var saved = cases[0]["review"] as! [String: Any]
        saved["expires"] = Int64(Date().timeIntervalSince1970) + 200
        var lost = false, identity = "xbt-regtest:" + String(repeating: "c", count: 64)
        JamStub.route = { request in
            let path = request.url!.path
            if path.hasSuffix("/identity") { return (200, "{\"wallet\":\"fixture.jmdat\",\"identity\":\"\(identity)\"}") }
            if path.hasSuffix("/capabilities") { return (200, "{\"version\":1,\"reviewed_direct_send\":true}") }
            if path.hasSuffix("/commit") { saved["state"] = "unknown"; if lost { return (504, "{}") } }
            return (200, String(decoding: try! JSONSerialization.data(withJSONObject: saved), as: UTF8.self))
        }
        let c = try client()
        let review = try await c.prepareSend(draft, authorization: auth)
        let request = try JSONSerialization.jsonObject(with: JamStub.bodies.last!) as! [String:Any]
        XCTAssertEqual(request["amount_sat"] as? Int, 20000); XCTAssertEqual(request["max_total_sat"] as? Int, 20500)
        identity = "xbt-regtest:" + String(repeating: "e", count: 64)
        do { _ = try await c.commitSend(review, draft: draft, authorization: auth); XCTFail("Changed wallet") } catch {}
        XCTAssertFalse(JamStub.requests.contains { $0.url!.path.hasSuffix("/commit") })
        identity = review.walletIdentity; lost = true
        do { _ = try await c.commitSend(review, draft: draft, authorization: auth); XCTFail("Lost response") } catch {}
        let observed = try await c.commitSend(review, draft: draft, authorization: auth)
        XCTAssertEqual(observed.state, .unknown)
        XCTAssertEqual(JamStub.requests.filter { $0.url!.path.hasSuffix("/commit") }.count, 1)
    }
    func testCoinJoinSendBindsReviewAndNeverRepeatsLostCommit() async throws {
        let auth = try JoinBlaketAuthorization(wallet: "fixture.jmdat", token: "synthetic-token")
        let draft = try JoinBlaketSendDraft(jar: 0, destination: "bcrt1qsyntheticrecipient", amountSat: 20000, feeRateMillisatVb: 1000, maxFeeSat: 500, coinjoin: true, id: String(repeating: "a", count: 64))
        let file = Bundle.module.url(forResource: "jam-send-review", withExtension: "json", subdirectory: "Fixtures")!
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [[String: Any]]
        var saved = cases.first { $0["name"] as? String == "reviewed CoinJoin" }!["review"] as! [String: Any]
        saved["expires"] = Int64(Date().timeIntervalSince1970) + 200
        var supported = false
        var lost = false, identity = "xbt-regtest:" + String(repeating: "c", count: 64)
        JamStub.route = { request in
            let path = request.url!.path
            if path.hasSuffix("/identity") { return (200, "{\"wallet\":\"fixture.jmdat\",\"identity\":\"\(identity)\"}") }
            if path.hasSuffix("/capabilities") { return (200, supported ? "{\"version\":2,\"reviewed_direct_send\":true,\"coinjoin_payments\":true}" : "{\"version\":1,\"reviewed_direct_send\":true}") }
            if path.hasSuffix("/commit") { saved["state"] = "unknown"; if lost { return (504, "{}") } }
            return (200, String(decoding: try! JSONSerialization.data(withJSONObject: saved), as: UTF8.self))
        }
        let c = try client()
        do { _ = try await c.prepareSend(draft, authorization: auth); XCTFail("Unsupported CoinJoin cannot use direct sends") } catch { XCTAssertTrue(error.localizedDescription.contains("No direct payment was requested")) }
        XCTAssertFalse(JamStub.requests.contains { $0.httpMethod == "POST" })
        supported = true
        let review = try await c.prepareSend(draft, authorization: auth)
        let request = try JSONSerialization.jsonObject(with: JamStub.bodies.last!) as! [String:Any]
        XCTAssertEqual(request["coinjoin"] as? Bool, true); XCTAssertEqual(request["rbf"] as? Bool, false)
        XCTAssertEqual(request["amount_sat"] as? Int, 20000); XCTAssertEqual(request["max_total_sat"] as? Int, 20500)
        identity = "xbt-regtest:" + String(repeating: "e", count: 64)
        do { _ = try await c.commitSend(review, draft: draft, authorization: auth); XCTFail("Changed wallet") } catch {}
        XCTAssertFalse(JamStub.requests.contains { $0.url!.path.hasSuffix("/commit") })
        identity = review.walletIdentity; lost = true
        do { _ = try await c.commitSend(review, draft: draft, authorization: auth); XCTFail("Lost response") } catch {}
        let observed = try await c.commitSend(review, draft: draft, authorization: auth)
        XCTAssertEqual(observed.state, .unknown)
        XCTAssertEqual(JamStub.requests.filter { $0.url!.path.hasSuffix("/commit") }.count, 1)
    }
    func testPaymentPairingPreservesModeAndNeverRepeatsLostCommit() async throws {
        for mode in 0...3 {
            let coinjoin = mode == 1, bond = mode == 2, withdrawal = mode == 3
            let bondTime: Int64? = withdrawal ? 1800000000 : bond ? 2100000000 : nil
            JamStub.requests = []; JamStub.bodies = []
            let pair = try JoinBlaketPairing(text: pairingText(["scope":"jars_pay_v1"]))
            XCTAssertTrue(pair.canSend)
            let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [JamStub.self]
            let client = try JoinBlaketClient(connection: pair.connection, configuration: configuration, pairing: pair)
            let auth = try pair.authorization()
            let draft = try JoinBlaketSendDraft(jar: 0, destination: "bcrt1qsyntheticrecipient", amountSat: 20000, feeRateMillisatVb: 1000, maxFeeSat: 500, coinjoin: coinjoin, bondLocktime: bondTime, bondOutpoint: withdrawal ? String(repeating: "1", count: 64) + ":0" : nil, id: String(repeating: "a", count: 64))
            let file = Bundle.module.url(forResource: "jam-send-review", withExtension: "json", subdirectory: "Fixtures")!
            let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [[String: Any]]
            var saved = (withdrawal ? cases.first { $0["name"] as? String == "reviewed bond withdrawal" }! : bond ? cases.first { $0["name"] as? String == "reviewed bond funding" }! : coinjoin ? cases.first { $0["name"] as? String == "reviewed CoinJoin" }! : cases[0])["review"] as! [String: Any]
            saved["expires"] = Int64(Date().timeIntervalSince1970) + 200
            var operations: [String] = [], revoked = false, fundingSupported = false
            JamStub.route = { request in
                XCTAssertEqual(request.url!.path,"/api/v1/paired-jars/request")
                let body = try! JSONSerialization.jsonObject(with: JamStub.bodies.last!) as! [String: Any]
                XCTAssertNil(body["token"]); XCTAssertNil(body["password"]); XCTAssertEqual(body["wallet"] as? String,pair.wallet)
                let op = body["operation"] as! String; operations.append(op)
                if revoked { return (401,"{}") }
                if op == "identity" { return (200,"{\"wallet\":\"fixture.jmdat\",\"identity\":\"xbt-regtest:\(String(repeating: "c", count: 64))\"}") }
                if op == "payment_capabilities" { return (200,"{\"version\":2,\"reviewed_direct_send\":true,\"coinjoin_payments\":true,\"bond_funding\":\(fundingSupported),\"bond_withdrawal\":\(fundingSupported)}") }
                if op == "prepare_payment" {
                    let terms = body["send"] as! [String: Any]
                    XCTAssertEqual(terms["coinjoin"] as? Bool,coinjoin)
                    XCTAssertEqual(terms["amount_sat"] as? Int,20000)
                    XCTAssertEqual(terms["bond_locktime"] as? Int64,bondTime)
                    XCTAssertEqual(terms["bond_outpoint"] as? String,draft.bondOutpoint)
                } else if op == "commit_payment" {
                    XCTAssertEqual(body["wallet_identity"] as? String,"xbt-regtest:" + String(repeating: "c", count: 64))
                    XCTAssertEqual(body["approval"] as? String,saved["approval"] as? String)
                    saved["state"] = "unknown"; return (504,"{}")
                } else { XCTAssertEqual(op,"payment_review") }
                return (200,String(decoding: try! JSONSerialization.data(withJSONObject: saved),as: UTF8.self))
            }
            if bond || withdrawal {
                do { _ = try await client.prepareSend(draft,authorization: auth); XCTFail("Unsupported bond funding") } catch {}
                XCTAssertFalse(operations.contains("prepare_payment"))
            }
            fundingSupported = true
            let review = try await client.prepareSend(draft,authorization: auth)
            XCTAssertFalse(operations.contains("commit_payment"))
            do { _ = try await client.commitSend(review,draft: draft,authorization: auth); XCTFail("Lost response") } catch {}
            let observed = try await client.commitSend(review,draft: draft,authorization: auth)
            XCTAssertEqual(observed.state,.unknown)
            XCTAssertEqual(operations.filter { $0 == "commit_payment" }.count,1)
            revoked = true
            do { _ = try await client.commitSend(review,draft: draft,authorization: auth); XCTFail("Revoked pairing") } catch {}
            XCTAssertEqual(operations.filter { $0 == "commit_payment" }.count,1)
        }
    }

    private func pairingText(_ changes: [String: Any] = [:]) throws -> String {
        var value: [String: Any] = ["kind":"paperclip-jars-v1", "scope":"jars_manage_v1", "endpoint":"https://host.example.invalid", "wallet":"fixture.jmdat",
                                  "token":"pj1_" + String(repeating: "a", count: 64), "expires":4_000_000_000, "certificate_sha256":""]
        value.merge(changes) { _, new in new }
        return "paperclip-jars:" + (try JSONSerialization.data(withJSONObject: value)).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    func testLivePairingTLSWithSyntheticGrant() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let origin = env["PAPERCLIP_PAIRING_TEST_ORIGIN"], let pins = env["PAPERCLIP_PAIRING_TEST_PINS"] else {
            throw XCTSkip("Requires a reachable Paperclip host and verified certificate fingerprints")
        }
        // No real grant is used. Reaching the host's authorization rejection
        // proves the production client completed TLS and sent its status request.
        for (fingerprints, valid) in [(pins, true), (String(repeating: "0", count: 64), false)] {
            let pair = try JoinBlaketPairing(text: pairingText(["endpoint":origin, "certificate_sha256":fingerprints]))
            let client = try JoinBlaketClient(connection: pair.connection, pairing: pair)
            do {
                _ = try await client.status(pair.authorization())
                XCTFail("Host accepted a synthetic grant")
            } catch JoinBlaketError.pairingUnavailable {
                XCTAssertTrue(valid, "An unrelated pin reached HTTP")
            } catch JoinBlaketError.pairingCertificateChanged {
                XCTAssertFalse(valid, "Verified pins failed TLS")
            }
        }
    }

    func testOnionPairingRequiresTorAndRetainsTLSPin() throws {
        let host = String(repeating: "a", count: 56) + ".onion"
        let pair = try JoinBlaketPairing(text: pairingText(["endpoint":"http://" + host]))
        XCTAssertTrue(pair.connection.useTor)
        XCTAssertEqual(pair.connection.torProxy, "builtin")
        let pin = String(repeating: "b", count: 64)
        let secure = try JoinBlaketPairing(text: pairingText(["endpoint":"https://" + host, "certificate_sha256":pin]))
        XCTAssertTrue(secure.connection.useTor)
        XCTAssertEqual(secure.connection.certificateSHA256, pin)
        var resolved = secure.connection; resolved.torProxy = "socks5h://127.0.0.1:19050"
        let configuration = URLSessionConfiguration.ephemeral
        _ = try JoinBlaketClient(connection: resolved, configuration: configuration, pairing: secure)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 90)
        XCTAssertEqual(configuration.proxyConfigurations.count, 1)
        XCTAssertFalse(try XCTUnwrap(configuration.proxyConfigurations.first).allowFailover)

        for changes: [String: Any] in [["endpoint":"http://short.onion"], ["endpoint":"https://short.onion"], ["endpoint":"http://" + host, "certificate_sha256":pin], ["endpoint":"http://" + host + "/?token=x"]] {
            XCTAssertThrowsError(try JoinBlaketPairing(text: pairingText(changes)))
        }
        var direct = secure.connection; direct.useTor = false
        XCTAssertThrowsError(try JoinBlaketClient(connection: direct, pairing: secure))
        var wrongPin = secure.connection; wrongPin.certificateSHA256 = ""
        XCTAssertThrowsError(try JoinBlaketClient(connection: wrongPin, pairing: secure))
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
        let draft = try JoinBlaketSendDraft(jar: 0, destination: "bcrt1qsyntheticrecipient", amountSat: 20000, feeRateMillisatVb: 1000, maxFeeSat: 500)
        do { _ = try await c.prepareSend(draft, authorization: pair.authorization()); XCTFail("Management grant cannot prepare a send") } catch {}
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
                if let quote = payment.quote, quote.purpose != "send" {
                    XCTAssertEqual(quote.bondUnlockDescription, quote.bond_locktime == nil ? "Unavailable — check your Jam host" : "2030-01-01 00:00 UTC")
                }
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
    func testOrderBookFixturesAndSorting() throws {
        struct Case: Decodable { let name: String; let valid: Bool; let value: JoinBlaketMarket }
        let url = Bundle.module.url(forResource: "jars-orderbook", withExtension: "json", subdirectory: "Fixtures")!
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        for row in rows {
            let data = try JSONSerialization.data(withJSONObject: row)
            let result = Result { let item = try JSONDecoder().decode(Case.self, from: data); try item.value.validate(amount: 50000, now: 2000000000); return item.value }
            XCTAssertEqual((try? result.get()) != nil, row["valid"] as? Bool, row["name"] as! String)
            if let book = try? result.get(), book.offers != nil {
                XCTAssertEqual(book.visibleOffers(eligibleOnly: false, largestFirst: false).map(\.id), [1,0,2])
                XCTAssertEqual(book.visibleOffers(eligibleOnly: true, largestFirst: false).map(\.id), [0])
                XCTAssertEqual(book.visibleOffers(eligibleOnly: false, largestFirst: true).map(\.id), [2,1,0])
            }
        }
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
