import Foundation
import CoreFoundation

public struct LightningOfferReview: Equatable, Sendable {
    public let amountMsat: UInt64?
    public let description: String
    public func requestedAmount(enteredSats: UInt64?) throws -> UInt64 {
        if let enteredSats {
            guard enteredSats > 0, enteredSats <= UInt64.max / 1000 else {
                throw LightningNodeError(message: "Enter a positive amount within the supported range.")
            }
            let entered = enteredSats * 1000
            if let amountMsat, amountMsat != entered {
                throw LightningNodeError(message: "The entered amount differs from this offer’s fixed amount. Clear the amount field to use the offer amount.")
            }
            return entered
        }
        guard let amountMsat else {
            throw LightningNodeError(message: "This offer has no fixed amount. Enter an amount, then request an invoice.")
        }
        return amountMsat
    }
    public static func decode(_ data: Data, now: Date = Date()) throws -> Self {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["type"] as? String == "bolt12 offer", value["valid"] as? Bool == true else { throw ConnectionError.response }
        guard value["offer_currency"] == nil, value["offer_quantity_max"] == nil, value["offer_recurrence"] == nil else {
            throw LightningNodeError(message: "Currency-priced, quantity, and recurring offers are not supported yet. Request a single-payment XBT offer or invoice.")
        }
        func number(_ value: Any) -> UInt64? {
            if let text = value as? String { return UInt64(text.hasSuffix("msat") ? String(text.dropLast(4)) : text) }
            if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { return UInt64(value.stringValue) }
            return nil
        }
        if let expiry = value["offer_absolute_expiry"] {
            guard let timestamp = number(expiry), Double(timestamp) > now.timeIntervalSince1970 else { throw ConnectionError.response }
        }
        var amount: UInt64?
        if let field = value["offer_amount_msat"] {
            guard let parsed = number(field), parsed > 0 else { throw ConnectionError.response }
            amount = parsed
        }
        return Self(amountMsat: amount, description: value["offer_description"] as? String ?? "")
    }
}
