import XCTest
import CryptoKit
@testable import PaperclipMobile

private final class OffersProtocol: URLProtocol {
    static var response: (URLRequest, [String: Any]) -> (Int, [String: Any]) = { _, _ in (500, [:]) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
            }
        }
        let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let (status, result) = Self.response(request, fields)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: result))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class LNDBolt12Tests: XCTestCase {
    func data(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    func node(_ implementation: LightningImplementation = .lnd) throws -> LightningNode {
        var connection = LightningConnection(); connection.implementation = implementation
        connection.endpoint = "https://node.example"; connection.credential = "abcd"
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [OffersProtocol.self]
        return try LightningNode(connection: connection, configuration: configuration)
    }
    func testCreateFixedAndAmountlessOffersUsesNativeREST() async throws {
        for amount: UInt64? in [21, nil] {
            OffersProtocol.response = { request, body in
                XCTAssertEqual(request.url?.path, "/v2/offers"); XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Grpc-Metadata-macaroon"), "abcd")
                XCTAssertEqual(body["amount_msat"] as? String, amount == nil ? "0" : "21000")
                XCTAssertNil(body["amount"])
                return (200, ["offer": ["bolt12": "lno1fixture", "active": true]])
            }
            let offer = try await node().offer(amount: amount, description: "Test offer")
            XCTAssertEqual(offer, "lno1fixture")
        }
    }
    func testDecodeAndFetchNeverSendPayment() async throws {
        var calls: [String] = []
        OffersProtocol.response = { request, body in
            let path = request.url!.path; calls.append(path)
            if path == "/v2/offers/decode" {
                XCTAssertEqual(body["bolt12"] as? String, "lno1fixture")
                return (200, ["type": "offer", "valid": true, "for_this_chain": true, "offer": ["amount_msat": "21001"]])
            }
            XCTAssertEqual(path, "/v2/offers/fetchinvoice")
            XCTAssertEqual(body["offer"] as? String, "lno1fixture")
            XCTAssertEqual(body["amount_msat"] as? String, "21001")
            XCTAssertEqual(body["timeout_seconds"] as? Int, 30)
            XCTAssertNil(body["timeout"])
            return (200, ["bolt12": "lni1fixture"])
        }
        let node = try node()
        let offer = try LightningOfferReview.decode(await node.decode("lno1fixture"), implementation: .lnd)
        let invoice = try await node.fetchOfferInvoice("lno1fixture", amountMsat: offer.amountMsat)
        XCTAssertEqual(invoice, "lni1fixture")
        XCTAssertEqual(calls, ["/v2/offers/decode", "/v2/offers/fetchinvoice"])
    }
    func testInvoiceReviewChecksChainSignatureHashAmountAndExpiry() throws {
        let fields: [String: Any] = ["payment_hash": Data(repeating: 1, count: 32).base64EncodedString(),
            "amount_msat": "21001", "created_at": "1900", "relative_expiry": 200, "signature_valid": true]
        let value: [String: Any] = ["type": "invoice", "for_this_chain": true, "valid": false, "invoice": fields]
        let now = Date(timeIntervalSince1970: 2000)
        let review = try LightningPaymentReview.decode(data(value), implementation: .lnd, now: now)
        XCTAssertEqual(review.hash, String(repeating: "01", count: 32)); XCTAssertEqual(review.millisatoshis, 21001)
        XCTAssertEqual(review.expiresAt, 2100)
        for patch in [["signature_valid": false], ["payment_hash": "not base64"], ["amount_msat": true],
                      ["amount_msat": "0"], ["relative_expiry": 50], ["created_at": String(UInt64.max)]] as [[String: Any]] {
            var bad = value; bad["invoice"] = fields.merging(patch) { _, new in new }
            XCTAssertThrowsError(try LightningPaymentReview.decode(data(bad), implementation: .lnd, now: now))
        }
        var wrongChain = value; wrongChain["for_this_chain"] = false
        XCTAssertThrowsError(try LightningPaymentReview.decode(data(wrongChain), implementation: .lnd, now: now))
    }
    func testOfferReviewRejectsWrongChainExpiredAndQuantityOffers() throws {
        let value: [String: Any] = ["type": "offer", "for_this_chain": true, "valid": true, "offer": ["amount_msat": "0"]]
        XCTAssertNil(try LightningOfferReview.decode(data(value), implementation: .lnd).amountMsat)
        for patch in [["for_this_chain": false], ["valid": false], ["type": "invoice"],
                      ["offer": ["quantity_any": true]], ["offer": ["quantity_max": "2"]],
                      ["offer": ["absolute_expiry": "1"]], ["offer": ["amount_msat": true]]] as [[String: Any]] {
            XCTAssertThrowsError(try LightningOfferReview.decode(data(value.merging(patch) { _, new in new }), implementation: .lnd))
        }
    }
    func testPaymentUsesExactReviewedInvoiceAndFeeCap() async throws {
        let preimage = Data(repeating: 7, count: 32), hash = Data(SHA256.hash(data: Data(repeating: 7, count: 32)))
        OffersProtocol.response = { request, body in
            XCTAssertEqual(request.url?.path, "/v2/offers/pay")
            XCTAssertEqual(body["invoice"] as? String, "lni1reviewed")
            XCTAssertNil(body["offer"])
            XCTAssertEqual(body["fee_limit_msat"] as? String, "2000")
            return (200, ["bolt12": "lni1reviewed", "payment_hash": hash.base64EncodedString(), "payment_preimage": preimage.base64EncodedString()])
        }
        let response = try await node().pay("lni1reviewed", maximumFee: 2)
        XCTAssertEqual(try LNDStreamResponse.terminalState(response, hash: hash.map { String(format: "%02x", $0) }.joined()), "succeeded")
        OffersProtocol.response = { _, _ in XCTFail("Zero budget must not reach the network"); return (500, [:]) }
        do { _ = try await node().pay("lni1reviewed", maximumFee: 0); XCTFail("accepted node default fee") } catch {}
        XCTAssertThrowsError(try LightningNode.validateLNDOfferFee(UInt64.max))
        XCTAssertThrowsError(try LNDBolt12.paymentResult(["bolt12": "lni1reviewed", "payment_hash": hash.base64EncodedString(), "payment_preimage": Data(repeating: 0, count: 32).base64EncodedString()], invoice: "lni1reviewed"))
    }
    private func encodedInvoice(_ bytes: [UInt8]) -> String {
        let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
        var result = "lni1", acc: UInt32 = 0, bits = 0
        for byte in bytes {
            acc = ((acc << 8) | UInt32(byte)) & 0xffff; bits += 8
            while bits >= 5 { bits -= 5; result.append(alphabet[Int((acc >> bits) & 31)]) }
        }
        if bits > 0 { result.append(alphabet[Int((acc << (5 - bits)) & 31)]) }
        return result
    }
    func testSignedInvoiceExpiryDistinguishesDefaultFromExplicitZero() throws {
        XCTAssertEqual(try LNDBolt12.relativeExpiry(encodedInvoice([164, 1, 1])), 7200)
        XCTAssertEqual(try LNDBolt12.relativeExpiry(encodedInvoice([166, 0])), 0)
        XCTAssertEqual(try LNDBolt12.relativeExpiry(encodedInvoice([166, 2, 0x1c, 0x20])), 7200)
        XCTAssertEqual(try LNDBolt12.relativeExpiry(encodedInvoice([166, 1, 200]).uppercased()), 200)
        for bytes: [UInt8] in [[166], [166, 2, 1], [166, 1, 0], [166, 5, 1, 2, 3, 4, 5],
                              [166, 0, 166, 0], [166, 0, 164, 0], [253, 0, 166, 0], [255, 1],
                              [166, 255, 255, 255, 255, 255, 255, 255, 255, 255]] {
            XCTAssertThrowsError(try LNDBolt12.relativeExpiry(encodedInvoice(bytes)))
        }
        XCTAssertThrowsError(try LNDBolt12.relativeExpiry("lni1q"))
        XCTAssertThrowsError(try LNDBolt12.relativeExpiry("lni1Qqqq"))
    }
    func testNativeDecodeRestoresDefaultExpiryButPreservesExplicitZero() async throws {
        for (tlv, expected): ([UInt8], UInt64) in [([164, 1, 1], 7200), ([166, 0], 0)] {
            OffersProtocol.response = { request, _ in
                XCTAssertEqual(request.url?.path, "/v2/offers/decode")
                return (200, ["type": "invoice", "for_this_chain": true, "invoice": ["relative_expiry": 0]])
            }
            let decoded = try await node().decode(encodedInvoice(tlv))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: decoded) as? [String: Any])
            XCTAssertEqual((json["invoice"] as? [String: Any])?["relative_expiry"] as? String, String(expected))
        }
    }
    func testUnavailableOffersAndExistingCLNRoute() async throws {
        OffersProtocol.response = { _, _ in (404, [:]) }
        do { _ = try await node().offer(amount: nil, description: "Test"); XCTFail("missing error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("offers API")) }
        OffersProtocol.response = { request, body in
            XCTAssertEqual(request.url?.path, "/v1/offer")
            XCTAssertEqual(body["amount"] as? String, "any")
            return (200, ["bolt12": "lno1cln", "active": true])
        }
        let offer = try await node(.cln).offer(amount: nil, description: "Test")
        XCTAssertEqual(offer, "lno1cln")
    }
}
