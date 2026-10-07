import Foundation
import CoreFoundation

public struct LightningPaymentReview: Equatable, Sendable {
    public let hash: String
    public let millisatoshis: UInt64
    public let expiresAt: UInt64
    public static func decode(_ data: Data, implementation: LightningImplementation, now: Date = Date()) throws -> Self {
        guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              decoded["valid"] as? Bool != false else { throw ConnectionError.response }
        if implementation == .cln {
            guard decoded["valid"] as? Bool == true,
                  ["bolt11 invoice", "bolt12 invoice"].contains(decoded["type"] as? String ?? "") else { throw ConnectionError.response }
        }
        let bolt12 = implementation == .cln && decoded["type"] as? String == "bolt12 invoice"
        if bolt12 && decoded["valid"] as? Bool != true { throw ConnectionError.response }
        guard let hash = decoded[bolt12 ? "invoice_payment_hash" : "payment_hash"] as? String,
              hash.count == 64, hash.allSatisfy(\.isHexDigit) else { throw ConnectionError.response }
        func number(_ value: Any?) -> UInt64? {
            if let text = value as? String { return UInt64(text.hasSuffix("msat") ? String(text.dropLast(4)) : text) }
            if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue >= 0, value.doubleValue.rounded(.down) == value.doubleValue {
                return UInt64(value.stringValue)
            }
            return nil
        }
        guard let amount = number(decoded[bolt12 ? "invoice_amount_msat" : implementation == .cln ? "amount_msat" : "num_msat"]), amount > 0,
              let created = number(decoded[bolt12 ? "invoice_created_at" : implementation == .cln ? "created_at" : "timestamp"]),
              let expiry = number(bolt12 ? (decoded["invoice_relative_expiry"] ?? 7200) : decoded["expiry"]), created <= UInt64.max - expiry,
              Double(created + expiry) > now.timeIntervalSince1970 else { throw ConnectionError.response }
        return Self(hash: hash.lowercased(), millisatoshis: amount, expiresAt: created + expiry)
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
