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
}
