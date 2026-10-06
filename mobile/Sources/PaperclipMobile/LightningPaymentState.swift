import Foundation

public struct LightningPaymentReview: Equatable, Sendable {
    public let hash: String
    public let millisatoshis: UInt64
    public static func decode(_ data: Data, implementation: LightningImplementation, now: Date = Date()) throws -> Self {
        guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hash = decoded["payment_hash"] as? String, hash.count == 64, hash.allSatisfy(\.isHexDigit),
              decoded["valid"] as? Bool != false else { throw ConnectionError.response }
        func number(_ value: Any?) -> UInt64? {
            if let text = value as? String { return UInt64(text.replacingOccurrences(of: "msat", with: "")) }
            if let value = value as? NSNumber, value.doubleValue >= 0, value.doubleValue.rounded(.down) == value.doubleValue {
                return UInt64(value.stringValue)
            }
            return nil
        }
        guard let amount = number(decoded[implementation == .cln ? "amount_msat" : "num_msat"]), amount > 0,
              let created = number(decoded[implementation == .cln ? "created_at" : "timestamp"]),
              let expiry = number(decoded["expiry"]), created <= UInt64.max - expiry,
              Double(created + expiry) > now.timeIntervalSince1970 else { throw ConnectionError.response }
        return Self(hash: hash.lowercased(), millisatoshis: amount)
    }
}

public enum LightningPaymentState {
    /// Missing, unknown, or in-flight records must never release a pending attempt.
    public static func terminalState(in data: Data, hash: String, implementation: LightningImplementation) throws -> String? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json[implementation == .cln ? "pays" : "payments"] as? [[String: Any]] else { throw ConnectionError.response }
        let matches = rows.filter { ($0["payment_hash"] as? String)?.lowercased() == hash.lowercased() }
        guard !matches.isEmpty else { return nil }
        let states = matches.map { ($0["status"] as? String ?? "unknown").lowercased() }
        // A concurrent or incomplete attempt takes precedence over an older failure.
        guard states.allSatisfy({ ["complete", "succeeded", "failed"].contains($0) }) else { return nil }
        return states.contains("complete") || states.contains("succeeded") ? "succeeded" : "failed"
    }
}
