import Foundation

public struct LNDStreamError: LocalizedError {
    public let code: Int
    public let message: String
    public var errorDescription: String? { "LND: \(message)" }
    // AlreadyExists is deliberately excluded: it may identify a live payment.
    public var definitelyRejected: Bool { [3, 7, 12, 16].contains(code) }
}

public enum LNDStreamResponse {
    public static func decode(_ data: Data) throws -> Data {
        guard data.count <= 256 * 1024,
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConnectionError.response }
        if let error = (envelope["error"] as? [String: Any]) ?? (envelope["code"] != nil ? envelope : nil), let code = error["code"] as? Int {
            throw LNDStreamError(code: code, message: String((error["message"] as? String ?? "Request failed").prefix(500)))
        }
        guard let result = envelope["result"] as? [String: Any],
              let hash = result["payment_hash"] as? String, hash.count == 64, hash.allSatisfy(\.isHexDigit),
              let status = result["status"] as? String,
              ["INITIATED", "IN_FLIGHT", "SUCCEEDED", "FAILED"].contains(status) else { throw ConnectionError.response }
        return try JSONSerialization.data(withJSONObject: result)
    }
    public static func terminalState(_ data: Data, hash: String) throws -> String? {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (value["payment_hash"] as? String)?.lowercased() == hash.lowercased() else { throw ConnectionError.response }
        switch value["status"] as? String {
        case "SUCCEEDED": return "succeeded"
        case "FAILED": return "failed"
        case "INITIATED", "IN_FLIGHT": return nil
        default: throw ConnectionError.response
        }
    }
}
