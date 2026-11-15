import Foundation
import CoreFoundation

// Lightning Fork offersrpc REST schema (protobuf bytes are base64; uint64s are strings).
// https://github.com/privkeyio/lightning-fork/blob/a60fbeccd56c6910868f37cf857ad78bae30b5e4/lnrpc/offersrpc/offers.proto
enum LNDBolt12 {
    static func number(_ value: Any?) throws -> UInt64 {
        if let text = value as? String, let number = UInt64(text) { return number }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
           let result = UInt64(number.stringValue) { return result }
        throw ConnectionError.response
    }
    static func hex(_ value: Any?) throws -> String {
        guard let text = value as? String, let bytes = Data(base64Encoded: text), bytes.count == 32 else { throw ConnectionError.response }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    static func offerReview(_ value: [String: Any], now: Date) throws -> LightningOfferReview {
        guard value["type"] as? String == "offer", value["valid"] as? Bool == true,
              value["for_this_chain"] as? Bool == true, let offer = value["offer"] as? [String: Any] else { throw ConnectionError.response }
        guard try number(offer["quantity_max"] ?? "0") == 0, offer["quantity_any"] as? Bool != true else {
            throw LightningNodeError(message: "Quantity offers are not supported yet. Request a single-payment XBT offer.")
        }
        let expiry = try number(offer["absolute_expiry"] ?? "0")
        guard expiry == 0 || Double(expiry) > now.timeIntervalSince1970 else { throw ConnectionError.response }
        let amount = try number(offer["amount_msat"] ?? "0")
        return LightningOfferReview(amountMsat: amount == 0 ? nil : amount, description: offer["description"] as? String ?? "")
    }
    static func invoiceReview(_ value: [String: Any], now: Date) throws -> LightningPaymentReview {
        // DecodeBolt12.valid applies only to offers. For invoices, check chain and signature explicitly.
        guard value["type"] as? String == "invoice", value["for_this_chain"] as? Bool == true,
              let invoice = value["invoice"] as? [String: Any], invoice["signature_valid"] as? Bool == true else { throw ConnectionError.response }
        let hash = try hex(invoice["payment_hash"])
        let amount = try number(invoice["amount_msat"]), created = try number(invoice["created_at"])
        let expiry = try number(invoice["relative_expiry"])
        guard amount > 0, created <= UInt64.max - expiry, Double(created + expiry) > now.timeIntervalSince1970 else { throw ConnectionError.response }
        return LightningPaymentReview(hash: hash, millisatoshis: amount, expiresAt: created + expiry)
    }
    // offersrpc collapses an absent relative-expiry TLV and an explicit zero into
    // protobuf zero. Read only this field from the signed invoice to distinguish
    // the BOLT12 two-hour default from an already-expired zero-duration invoice.
    static func relativeExpiry(_ invoice: String) throws -> UInt64 {
        guard invoice.utf8.count <= 256 * 1024,
              invoice == invoice.lowercased() || invoice == invoice.uppercased(),
              invoice.lowercased().hasPrefix("lni1") else { throw ConnectionError.response }
        let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l".utf8)
        var bytes: [UInt8] = [], accumulator: UInt32 = 0, bits = 0
        for character in invoice.lowercased().utf8.dropFirst(4) {
            guard let word = alphabet.firstIndex(of: character) else { throw ConnectionError.response }
            accumulator = ((accumulator << 5) | UInt32(word)) & 0xffff
            bits += 5
            if bits >= 8 { bits -= 8; bytes.append(UInt8((accumulator >> bits) & 255)) }
        }
        guard !bytes.isEmpty, bits < 5, accumulator & ((1 << bits) - 1) == 0 else { throw ConnectionError.response }
        var offset = 0
        func bigSize() throws -> UInt64 {
            guard offset < bytes.count else { throw ConnectionError.response }
            let prefix = bytes[offset]; offset += 1
            if prefix < 253 { return UInt64(prefix) }
            let length = prefix == 253 ? 2 : prefix == 254 ? 4 : 8
            guard length <= bytes.count - offset else { throw ConnectionError.response }
            var value: UInt64 = 0
            for byte in bytes[offset..<(offset + length)] { value = (value << 8) | UInt64(byte) }
            offset += length
            guard value >= (prefix == 253 ? 253 : prefix == 254 ? 65536 : 4294967296) else { throw ConnectionError.response }
            return value
        }
        var previous: UInt64?, expiry: UInt64 = 7200
        while offset < bytes.count {
            let type = try bigSize(), length = try bigSize()
            guard previous.map({ type > $0 }) ?? true, length <= UInt64(bytes.count - offset) else { throw ConnectionError.response }
            previous = type
            if type == 166 {
                guard length <= 4, length == 0 || bytes[offset] != 0 else { throw ConnectionError.response }
                expiry = 0
                for byte in bytes[offset..<(offset + Int(length))] { expiry = (expiry << 8) | UInt64(byte) }
            }
            offset += Int(length)
        }
        return expiry
    }
    static func paymentResult(_ value: [String: Any], invoice: String) throws -> Data {
        let hash = try hex(value["payment_hash"]), preimage = try hex(value["payment_preimage"])
        guard value["bolt12"] as? String == invoice, BridgeInvoice.verifies(preimage: preimage, hash: hash) else { throw ConnectionError.response }
        // Use the same exact-hash terminal-state path as LND's router responses.
        return try JSONSerialization.data(withJSONObject: ["payment_hash": hash, "status": "SUCCEEDED"])
    }
}
