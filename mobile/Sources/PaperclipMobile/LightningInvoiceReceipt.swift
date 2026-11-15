import Foundation

/// An invoice's preimage is known before it is paid. Only the node's paid state
/// and received amount establish receipt; preimage possession alone does not.
public struct LightningInvoiceReceipt: Equatable, Sendable {
    public enum State: String, Sendable { case waiting, accepted, paid, ended }
    public let state: State
    public static func decode(_ data: Data, implementation: LightningImplementation, invoice: BridgeInvoice) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConnectionError.response }
        func msat(_ value: Any?) -> UInt64? {
            if let string = value as? String { return UInt64(string.hasSuffix("msat") ? String(string.dropLast(4)) : string) }
            if let number = value as? NSNumber { return UInt64(number.stringValue) }
            return nil
        }
        if implementation == .cln {
            guard let rows = object["invoices"] as? [[String: Any]],
                  let row = rows.first(where: { ($0["payment_hash"] as? String)?.lowercased() == invoice.hash }),
                  let bolt11 = row["bolt11"] as? String, try BridgeInvoice(bolt11) == invoice,
                  msat(row["amount_msat"]) == invoice.msat else { throw ConnectionError.response }
            switch row["status"] as? String {
            case "unpaid": return Self(state: .waiting)
            case "expired": return Self(state: .ended)
            case "paid":
                guard let received = msat(row["amount_received_msat"]), received >= invoice.msat else { throw ConnectionError.response }
                return Self(state: .paid)
            default: throw ConnectionError.response
            }
        }
        guard let encodedHash = object["r_hash"] as? String, let bytes = Data(base64Encoded: encodedHash),
              bytes.map({ String(format: "%02x", $0) }).joined() == invoice.hash,
              let request = object["payment_request"] as? String, try BridgeInvoice(request) == invoice,
              msat(object["value_msat"]) == invoice.msat else { throw ConnectionError.response }
        switch object["state"] as? String {
        case "SETTLED":
            guard object["settled"] as? Bool == true, let received = msat(object["amt_paid_msat"]), received >= invoice.msat else { throw ConnectionError.response }
            return Self(state: .paid)
        case "OPEN": return Self(state: .waiting)
        case "ACCEPTED": return Self(state: .accepted)
        case "CANCELED": return Self(state: .ended)
        default: throw ConnectionError.response
        }
    }
}
