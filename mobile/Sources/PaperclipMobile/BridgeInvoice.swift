import Foundation
import CryptoKit

public enum BridgeError: LocalizedError {
    case invalidInvoice, wrongNetwork, invalidQuote, expired, unavailable(String)
    public var errorDescription: String? {
        switch self {
        case .invalidInvoice: return "Use a valid, fixed-amount Lightning invoice."
        case .wrongNetwork: return "Use a Spamcoin (BTC) mainnet invoice here. XBT invoices belong in the regular payment flow."
        case .invalidQuote: return "The bridge invoice does not match this payment. Nothing was sent."
        case .expired: return "This quote has expired. Review a new quote before paying."
        case .unavailable(let message): return message
        }
    }
}

/// Checks encoding and payment commitments. Signature validation remains with the
/// bridge's target decoder and the funding wallet's native invoice decoder.
public struct BridgeInvoice: Equatable, Codable, Sendable {
    public let text: String
    public let hash: String
    public let msat: UInt64
    public let expiresAt: UInt64
    public let isXBT: Bool

    public init(_ input: String) throws {
        let raw = PaymentInput.normalized(input)
        guard (100...2000).contains(raw.utf8.count), raw == raw.lowercased() || raw == raw.uppercased() else { throw BridgeError.invalidInvoice }
        let s = raw.lowercased()
        guard let separator = s.lastIndex(of: "1") else { throw BridgeError.invalidInvoice }
        let hrp = String(s[..<separator])
        guard hrp.hasPrefix("lnbc"), !hrp.hasPrefix("lnbcrt") else { throw BridgeError.wrongNetwork }
        let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
        let words = try s[s.index(after: separator)...].map { c -> UInt8 in
            guard let i = alphabet.firstIndex(of: c) else { throw BridgeError.invalidInvoice }; return UInt8(i)
        }
        let expanded = hrp.utf8.map { $0 >> 5 } + [0] + hrp.utf8.map { $0 & 31 }
        let generators: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var check: UInt32 = 1
        for w in expanded + words {
            let top = check >> 25; check = ((check & 0x1ffffff) << 5) ^ UInt32(w)
            for i in 0..<5 where ((top >> i) & 1) != 0 { check ^= generators[i] }
        }
        guard check == 1, words.count >= 117 else { throw BridgeError.invalidInvoice }
        var amount = String(hrp.dropFirst(4)), multiplier: UInt64 = 100_000_000_000
        if let suffix = amount.last, !suffix.isNumber {
            amount.removeLast()
            switch suffix {
            case "m": multiplier = 100_000_000
            case "u": multiplier = 100_000
            case "n": multiplier = 100
            case "p": multiplier = 0
            default: throw BridgeError.invalidInvoice
            }
        }
        guard !amount.isEmpty, amount.utf8.allSatisfy({ (48...57).contains($0) }), let n = UInt64(amount), n > 0 else { throw BridgeError.invalidInvoice }
        if multiplier == 0 {
            guard n % 10 == 0 else { throw BridgeError.invalidInvoice }; msat = n / 10
        } else {
            let product = n.multipliedReportingOverflow(by: multiplier)
            guard !product.overflow else { throw BridgeError.invalidInvoice }; msat = product.partialValue
        }
        guard msat > 0, msat <= 2_100_000_000_000_000_000 else { throw BridgeError.invalidInvoice }
        let fields = Array(words.dropLast(110))
        func integer(_ values: ArraySlice<UInt8>) throws -> UInt64 {
            var n: UInt64 = 0
            for v in values {
                guard n <= (UInt64.max - UInt64(v)) / 32 else { throw BridgeError.invalidInvoice }
                n = n * 32 + UInt64(v)
            }
            return n
        }
        let timestamp = try integer(fields[0..<7])
        var expiry: UInt64 = 3600, paymentHash: String?, xbt = false, seen = Set<UInt8>(), i = 7
        while i < fields.count {
            guard i + 3 <= fields.count else { throw BridgeError.invalidInvoice }
            let tag = fields[i], length = Int(fields[i + 1]) * 32 + Int(fields[i + 2]); i += 3
            guard i + length <= fields.count else { throw BridgeError.invalidInvoice }
            let field = fields[i..<(i + length)]; i += length
            if [1, 6, 5].contains(tag) {
                guard seen.insert(tag).inserted else { throw BridgeError.invalidInvoice }
            }
            if tag == 1 {
                guard length == 52, field.last! & 15 == 0 else { throw BridgeError.invalidInvoice }
                var acc: UInt32 = 0, bits = 0, bytes: [UInt8] = []
                for w in field {
                    acc = ((acc << 5) | UInt32(w)) & 0xffff; bits += 5
                    if bits >= 8 { bits -= 8; bytes.append(UInt8((acc >> bits) & 255)) }
                }
                paymentHash = bytes.map { String(format: "%02x", $0) }.joined()
            } else if tag == 6 { expiry = try integer(field) }
            else if tag == 5 {
                for bit in [512, 513] where length > bit / 5 {
                    if field[field.endIndex - 1 - bit / 5] & (1 << (bit % 5)) != 0 { xbt = true }
                }
            }
        }
        guard let paymentHash, timestamp <= UInt64.max - expiry else { throw BridgeError.invalidInvoice }
        text = s; hash = paymentHash; expiresAt = timestamp + expiry; isXBT = xbt
    }

    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }

    public func validateTarget(direction: BridgeDirection = .paySpamcoin, now: Date = Date()) throws {
        guard isXBT == direction.targetIsXBT else {
            throw BridgeError.unavailable(direction == .receiveXBT ? "Receive requires an XBT mainnet invoice from your Lightning node." : "Pay requires a Spamcoin (BTC) mainnet invoice.")
        }
        guard Double(expiresAt) > now.timeIntervalSince1970 + 300 else {
            throw BridgeError.unavailable("Use a new invoice with at least five minutes remaining.")
        }
    }
    public static func verifies(preimage: String, hash: String) -> Bool {
        guard preimage.count == 64, preimage.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }) else { return false }
        let chars = Array(preimage)
        let bytes = stride(from: 0, to: 64, by: 2).compactMap { UInt8(String(chars[$0...$0 + 1]), radix: 16) }
        return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined() == hash.lowercased()
    }
}
