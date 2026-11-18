import Foundation
import CoreFoundation

/// Recovery metadata only. Binding an older record never authorizes a payment.
public struct PendingNodePayment: Codable, Equatable, Sendable {
    public let invoice: String
    public let hash: String
    public let endpoint: String?
    public let implementation: LightningImplementation?
    public init(invoice: String, hash: String, connection: LightningConnection) {
        self.invoice = invoice; self.hash = hash
        endpoint = connection.endpoint; implementation = connection.implementation
    }
    public var needsNodeReview: Bool { endpoint == nil && implementation == nil }
    public func validate() throws {
        guard !invoice.isEmpty, invoice.utf8.count <= 16_384,
              hash.utf8.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              (endpoint == nil) == (implementation == nil),
              endpoint.map({ !$0.isEmpty && $0.utf8.count <= 4096 }) ?? true else { throw ConnectionError.response }
    }
    public func matches(_ connection: LightningConnection) -> Bool {
        !needsNodeReview && endpoint == connection.endpoint && implementation == connection.implementation
    }
    public func assigningOriginalNode(_ connection: LightningConnection) throws -> Self {
        try validate(); try connection.validate()
        guard needsNodeReview else { throw ConnectionError.response }
        return Self(invoice: invoice, hash: hash, connection: connection)
    }
}

public struct LightningPaymentReview: Equatable, Sendable {
    public let hash: String
    public let millisatoshis: UInt64
    public let expiresAt: UInt64
    public static func decode(_ data: Data, implementation: LightningImplementation, now: Date = Date()) throws -> Self {
        guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConnectionError.response }
        if implementation == .lnd, decoded["type"] as? String == "invoice" {
            return try LNDBolt12.invoiceReview(decoded, now: now)
        }
        guard decoded["valid"] as? Bool != false else { throw ConnectionError.response }
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
