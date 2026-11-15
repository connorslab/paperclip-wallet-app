import XCTest
import CryptoKit
@testable import PaperclipMobile

final class LightningBridgeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    // Encoding fixtures intentionally have dummy signatures: BridgeInvoice is a
    // commitment parser, not the funding wallet's signature verifier.
    private func invoice(xbt: Bool = false, amount: String = "10000n", hashByte: UInt8 = 1, expiry: UInt64 = 3600) -> String {
        let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l"), hrp = "lnbc" + amount
        func words(_ n: UInt64, count: Int) -> [UInt8] { (0..<count).reversed().map { UInt8((n >> ($0 * 5)) & 31) } }
        var data = words(1_800_000_000, count: 7)
        var hash: [UInt8] = [], acc: UInt32 = 0, bits = 0
        for b in [UInt8](repeating: hashByte, count: 32) {
            acc = (acc << 8 | UInt32(b)) & 0xffff; bits += 8
            while bits >= 5 { bits -= 5; hash.append(UInt8((acc >> bits) & 31)) }
        }
        if bits > 0 { hash.append(UInt8((acc << (5 - bits)) & 31)) }
        data += [1, 1, 20] + hash
        data += [6, 0, 7] + words(expiry, count: 7)
        if xbt { var features = [UInt8](repeating: 0, count: 103); features[0] = 8; data += [5, 3, 7] + features }
        data += [UInt8](repeating: 0, count: 104)
        var polymod: UInt32 = 1
        let expanded = hrp.utf8.map { $0 >> 5 } + [0] + hrp.utf8.map { $0 & 31 }
        let generators: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        for word in expanded + data + [UInt8](repeating: 0, count: 6) {
            let top = polymod >> 25; polymod = ((polymod & 0x1ffffff) << 5) ^ UInt32(word)
            for i in 0..<5 where (top >> i) & 1 != 0 { polymod ^= generators[i] }
        }
        data += words(UInt64(polymod ^ 1), count: 6)
        return hrp + "1" + String(data.map { alphabet[Int($0)] })
    }
    private func quote(_ hold: String, hash: String, pay: UInt64 = 1000, expiry: UInt64 = 1_800_000_060, sat: Double = 1000) throws -> BridgeQuote {
        let data = try JSONSerialization.data(withJSONObject: ["hold_invoice": hold, "hash": hash, "sat": sat, "pay_sat": pay,
            "rate": 0.5, "spread": 0.02, "expires_at": expiry, "token": String(repeating: "a", count: 32)])
        return try JSONDecoder().decode(BridgeQuote.self, from: data)
    }
    func testNetworkAmountAndChecksum() throws {
        let target = try BridgeInvoice(invoice())
        XCTAssertEqual(target.msat, 1_000_000); XCTAssertFalse(target.isXBT)
        try target.validateTarget(now: now)
        XCTAssertTrue(try BridgeInvoice(invoice(xbt: true)).isXBT)
        XCTAssertThrowsError(try BridgeInvoice(invoice(xbt: true)).validateTarget(now: now))
        XCTAssertThrowsError(try BridgeInvoice(invoice(amount: "")))
        XCTAssertThrowsError(try BridgeInvoice(invoice(amount: "1p")))
        XCTAssertThrowsError(try BridgeInvoice(invoice(amount: "999999999999999999999999999m")))
        XCTAssertThrowsError(try BridgeInvoice(invoice().dropLast() + "q"))
        XCTAssertThrowsError(try BridgeInvoice("L" + invoice().dropFirst()))
        XCTAssertEqual(try BridgeInvoice(invoice().uppercased()).hash, target.hash)
    }
    func testBindingRejectsWrongHashAmountNetworkAndExpiry() throws {
        let target = try BridgeInvoice(invoice()), hold = invoice(xbt: true)
        XCTAssertEqual(try quote(hold, hash: target.hash).validate(target: target, now: now).hash, target.hash)
        XCTAssertThrowsError(try quote(invoice(xbt: true, hashByte: 2), hash: target.hash).validate(target: target, now: now))
        XCTAssertThrowsError(try quote(hold, hash: target.hash, pay: 999).validate(target: target, now: now))
        XCTAssertThrowsError(try quote(hold, hash: target.hash, sat: 999).validate(target: target, now: now))
        XCTAssertThrowsError(try quote(invoice(), hash: target.hash).validate(target: target, now: now))
        XCTAssertThrowsError(try quote(hold, hash: target.hash, expiry: 1_800_000_004).validate(target: target, now: now))
        XCTAssertThrowsError(try quote(hold, hash: target.hash, expiry: 1_800_004_000).validate(target: target, now: now))
        XCTAssertThrowsError(try BridgeInvoice(invoice(expiry: 299)).validateTarget(now: now))
    }
    func testPreimageProof() {
        let data = Data(repeating: 7, count: 32), preimage = String(repeating: "07", count: 32)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(BridgeInvoice.verifies(preimage: preimage, hash: hash))
        XCTAssertFalse(BridgeInvoice.verifies(preimage: String(repeating: "08", count: 32), hash: hash))
        XCTAssertFalse(BridgeInvoice.verifies(preimage: "bad", hash: hash))
    }
    func testProofOfWorkAndBounds() async throws {
        let hash = String(repeating: "01", count: 32), challenge = "fixed-test-challenge"
        let nonce = try await BridgeProofOfWork.solve(challenge: challenge, bits: 8, hash: hash)
        XCTAssertEqual(Array(SHA256.hash(data: Data("\(challenge):\(hash):\(nonce)".utf8))).first, 0)
        do { _ = try await BridgeProofOfWork.solve(challenge: challenge, bits: 32, hash: hash); XCTFail("Unbounded work accepted") } catch {}
    }
    func testReverseDirectionAndPersistedInvoiceValidation() throws {
        let target = try BridgeInvoice(invoice(xbt: true))
        try target.validateTarget(direction: .receiveXBT, now: now)
        XCTAssertThrowsError(try BridgeInvoice(invoice()).validateTarget(direction: .receiveXBT, now: now))
        let reverse = try quote(invoice(), hash: target.hash)
        XCTAssertFalse(try reverse.validate(target: target, direction: .receiveXBT, now: now).isXBT)
        XCTAssertThrowsError(try reverse.validate(target: target, now: now))
        XCTAssertThrowsError(try quote(invoice(xbt: true), hash: target.hash).validate(target: target, direction: .receiveXBT, now: now))
        XCTAssertThrowsError(try quote(invoice(hashByte: 2), hash: target.hash).validate(target: target, direction: .receiveXBT, now: now))
        XCTAssertThrowsError(try quote(invoice(), hash: target.hash, pay: 999).validate(target: target, direction: .receiveXBT, now: now))
        XCTAssertEqual(try JSONDecoder().decode(BridgeInvoice.self, from: JSONEncoder().encode(target)), target)
        XCTAssertThrowsError(try JSONDecoder().decode(BridgeInvoice.self, from: JSONEncoder().encode("not an invoice")))
    }
    func testCLNReceiptRequiresPaidStateAndFullAmount() throws {
        let target = try BridgeInvoice(invoice(xbt: true))
        var row: [String: Any] = ["bolt11": target.text, "payment_hash": target.hash, "amount_msat": 1_000_000,
            "status": "unpaid", "payment_preimage": String(repeating: "01", count: 32)]
        func decode() throws -> LightningInvoiceReceipt {
            try .decode(JSONSerialization.data(withJSONObject: ["invoices": [row]]), implementation: .cln, invoice: target)
        }
        XCTAssertEqual(try decode().state, .waiting)
        row["status"] = "paid"; row["amount_received_msat"] = "1000000msat"
        XCTAssertEqual(try decode().state, .paid)
        row["amount_received_msat"] = 999999
        XCTAssertThrowsError(try decode())
        row["amount_received_msat"] = 1_000_000; row["payment_hash"] = String(repeating: "02", count: 32)
        XCTAssertThrowsError(try decode())
    }
    func testLNDReceiptBindsHashInvoiceAndPaidState() throws {
        let target = try BridgeInvoice(invoice(xbt: true))
        var row: [String: Any] = ["payment_request": target.text, "r_hash": Data(repeating: 1, count: 32).base64EncodedString(),
            "value_msat": "1000000", "amt_paid_msat": "1000000", "settled": false, "state": "OPEN"]
        func decode() throws -> LightningInvoiceReceipt {
            try .decode(JSONSerialization.data(withJSONObject: row), implementation: .lnd, invoice: target)
        }
        XCTAssertEqual(try decode().state, .waiting)
        row["state"] = "ACCEPTED"
        XCTAssertEqual(try decode().state, .accepted)
        row["state"] = "SETTLED"
        XCTAssertThrowsError(try decode())
        row["settled"] = true
        XCTAssertEqual(try decode().state, .paid)
        row["amt_paid_msat"] = "999999"
        XCTAssertThrowsError(try decode())
        row["amt_paid_msat"] = "1000000"; row["payment_request"] = invoice(xbt: true, hashByte: 2)
        XCTAssertThrowsError(try decode())
    }

    func testUSDEquivalentUsesRateDirectionWithoutAddingSpreadAgain() throws {
        XCTAssertEqual(try XCTUnwrap(BridgeDirection.paySpamcoin.xbtEquivalentSats(spamcoinSats: 1000, rate: 0.005)), 200_000, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(BridgeDirection.receiveXBT.xbtEquivalentSats(spamcoinSats: 1050, rate: 200)), 210_000, accuracy: 0.0001)
        XCTAssertEqual(BridgeDirection.receiveXBT.xbtEquivalentSats(spamcoinSats: 0, rate: 200), 0)
        XCTAssertNil(BridgeDirection.paySpamcoin.xbtEquivalentSats(spamcoinSats: 1000, rate: 0))
        XCTAssertNil(BridgeDirection.receiveXBT.xbtEquivalentSats(spamcoinSats: -1, rate: 200))
        XCTAssertNil(BridgeDirection.paySpamcoin.xbtEquivalentSats(spamcoinSats: .nan, rate: 1))
        XCTAssertNil(BridgeDirection.receiveXBT.xbtEquivalentSats(spamcoinSats: 1000, rate: .infinity))
        XCTAssertNil(BridgeDirection.receiveXBT.xbtEquivalentSats(spamcoinSats: .greatestFiniteMagnitude, rate: 200))
    }

}
