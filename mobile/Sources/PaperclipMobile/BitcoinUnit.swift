import Foundation

public enum BitcoinUnit: String, CaseIterable, Identifiable {
    case sats, xbt
    public var id: String { rawValue }
    public var title: String { self == .sats ? "sats" : "XBT" }
    public var amountPrompt: String { "Amount in \(title)" }
    // Exact integer conversion; no floating-point rounding in payment amounts.
    public func parse(_ input: String) -> UInt64? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !text.isEmpty, parts.count <= (self == .sats ? 1 : 2), !parts[0].isEmpty,
              parts.allSatisfy({ $0.allSatisfy({ $0 >= "0" && $0 <= "9" }) }), let whole = UInt64(parts[0]) else { return nil }
        if self == .sats { return whole <= 2_100_000_000_000_000 ? whole : nil }
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard fraction.count <= 8, whole <= 21_000_000 else { return nil }
        let remainder = UInt64(fraction + String(repeating: "0", count: 8 - fraction.count)) ?? 0
        let sats = whole * 100_000_000 + remainder
        return sats <= 2_100_000_000_000_000 ? sats : nil
    }
    public func input(_ sats: UInt64) -> String {
        if self == .sats { return String(sats) }
        let remainder = String(sats % 100_000_000)
        var fraction = String(repeating: "0", count: 8 - remainder.count) + remainder
        while fraction.last == "0" { fraction.removeLast() }
        return String(sats / 100_000_000) + (fraction.isEmpty ? "" : "." + fraction)
    }
    public func number(_ sats: UInt64) -> String { self == .sats ? sats.formatted() : input(sats) }
    public func display(_ sats: UInt64?) -> String { sats.map { "\(number($0)) \(title)" } ?? "—" }
    public func signed(_ sats: Int64) -> String { (sats < 0 ? "−" : "") + display(sats.magnitude) }
}
