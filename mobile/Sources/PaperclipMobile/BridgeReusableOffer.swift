import Foundation

/// Public binding response. The management key is never part of a shareable offer.
public struct BridgeReusableOffer: Codable, Equatable, Sendable {
    public let offer: String
    public let direction: BridgeDirection
    public let revoked: Bool
    public func validate() throws { try Self.validateOffer(offer, xbt: !direction.targetIsXBT, now: 0) }
    public static func validToken(_ token: String) -> Bool {
        token.utf8.count == 64 && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } && token.contains { $0 != "0" }
    }
    /// Bounded canonical TLV/network/amount checks; the bridge performs full offer
    /// validation. An offer is not a payment authorization or proof of receipt.
    public static func validateOffer(_ text: String, xbt: Bool, now: UInt64 = UInt64(Date().timeIntervalSince1970)) throws {
        func reject() -> BridgeError { .unavailable("Use an unexpired, amountless mainnet BOLT12 offer for the selected receiving currency.") }
        guard (5...16384).contains(text.utf8.count), text == text.lowercased() || text == text.uppercased(), text.lowercased().hasPrefix("lno1") else { throw reject() }
        let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l".utf8)
        var bytes = [UInt8](), accumulator = 0, bits = 0
        for c in text.lowercased().utf8.dropFirst(4) {
            guard let n = alphabet.firstIndex(of: c) else { throw reject() }
            accumulator = (accumulator << 5 | n) & 65535; bits += 5
            if bits >= 8 { bits -= 8; bytes.append(UInt8((accumulator >> bits) & 255)) }
        }
        guard bits < 5, accumulator & ((1 << bits) - 1) == 0 else { throw reject() }
        var offset = 0, previous: UInt64?, fields = [UInt64: [UInt8]]()
        func bigSize() throws -> UInt64 {
            guard offset < bytes.count else { throw reject() }
            let first = bytes[offset]; offset += 1
            if first < 253 { return UInt64(first) }
            let count = first == 253 ? 2 : first == 254 ? 4 : 8
            guard offset + count <= bytes.count else { throw reject() }
            var n: UInt64 = 0
            for b in bytes[offset..<offset + count] { n = n << 8 | UInt64(b) }; offset += count
            guard n >= (count == 2 ? 253 : count == 4 ? 65536 : 4294967296) else { throw reject() }; return n
        }
        while offset < bytes.count {
            let type = try bigSize(), length = try bigSize()
            guard previous.map({ type > $0 }) ?? true, length <= UInt64(bytes.count - offset), type < 80 || (1_000_000_000...1_999_999_999).contains(type) else { throw reject() }
            fields[type] = Array(bytes[offset..<offset + Int(length)]); offset += Int(length); previous = type
        }
        guard fields[6] == nil, fields[8] == nil, fields[20] == nil, fields[22] != nil || fields[16] != nil else { throw reject() }
        if let chains = fields[2] {
            let mainnet: [UInt8] = stride(from: 0, to: 64, by: 2).map { index in
                let hex = Array("6fe28c0ab6f1b372c1a6a246ae63f74f931e8365e15a089c68d6190000000000")
                return UInt8(String(hex[index...index + 1]), radix: 16)!
            }
            guard chains == mainnet else { throw reject() }
        }
        let features = fields[12] ?? []
        let requiredXBT = features.count > 64 && features[features.count - 65] & 1 != 0
        let optionalXBT = features.count > 64 && features[features.count - 65] & 2 != 0
        guard requiredXBT == xbt, !optionalXBT || requiredXBT else { throw reject() }
        if let expiry = fields[14] {
            guard expiry.count <= 8, expiry.first != 0 else { throw reject() }
            let value = expiry.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            guard value > now else { throw reject() }
        }
    }
}
