import Foundation

public enum PaymentInput {
    public static func normalized(_ text: String) -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.lowercased().hasPrefix("lightning:") ? String(value.dropFirst(10)) : value
    }
    // Presentation hint only. The native parser validates the request and amount.
    public static func isBolt11(_ text: String) -> Bool {
        let value = normalized(text).lowercased()
        return ["lnbc", "lntb", "lnbcrt"].contains { value.hasPrefix($0) }
    }
    public struct ScannedPayment: Equatable {
        public let destination: String
        public let amountSat: UInt64?
    }
    public enum ScanError: LocalizedError {
        case invalid
        public var errorDescription: String? { "This QR code is not a supported payment request. Use an address, Lightning invoice, offer, or Bitcoin URI without unsupported required parameters." }
    }
    public static func scanned(_ text: String) throws -> ScannedPayment {
        let value = normalized(text)
        guard !value.isEmpty, value.utf8.count <= 16384, !value.contains(where: { $0.isWhitespace }) else { throw ScanError.invalid }
        if value.lowercased().hasPrefix("bitcoin:") {
            guard let uri = URLComponents(string: value), uri.host == nil, uri.fragment == nil,
                  !uri.path.isEmpty, !uri.path.contains("/"), !uri.path.contains("%") else { throw ScanError.invalid }
            let items = uri.queryItems ?? []
            guard !items.contains(where: { $0.name.lowercased().hasPrefix("req-") }),
                  items.filter({ $0.name == "amount" }).count <= 1 else { throw ScanError.invalid }
            var sats: UInt64?
            if let item = items.first(where: { $0.name == "amount" }) {
                guard let value = item.value else { throw ScanError.invalid }
                let parts = value.split(separator: ".", omittingEmptySubsequences: false)
                guard (1...2).contains(parts.count), !parts[0].isEmpty,
                      parts.allSatisfy({ $0.allSatisfy({ $0 >= "0" && $0 <= "9" }) }),
                      parts.count == 1 || (1...8).contains(parts[1].count),
                      let whole = UInt64(parts[0]), whole <= 21_000_000 else { throw ScanError.invalid }
                let fraction = parts.count == 2 ? String(parts[1]) : ""
                let fractionalSats = UInt64(fraction + String(repeating: "0", count: 8 - fraction.count)) ?? 0
                let amount = whole * 100_000_000 + fractionalSats
                guard amount > 0, amount <= 2_100_000_000_000_000 else { throw ScanError.invalid }
                sats = amount
            }
            return ScannedPayment(destination: uri.path, amountSat: sats)
        }
        guard !value.contains(":"), !value.contains("?"), !value.contains("#") else { throw ScanError.invalid }
        return ScannedPayment(destination: value, amountSat: nil)
    }

}
