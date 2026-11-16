import Foundation
import CryptoKit

public enum BridgeDirection: String, Codable, Sendable {
    case paySpamcoin = "toSHA256"
    case receiveXBT = "toBLAKE2b"
    public var targetIsXBT: Bool { self == .receiveXBT }
    /// Convert BTC sats to XBT sats using the quote's direction-specific rate.
    /// The spread is already reflected in the quoted invoice amounts.
    public func xbtEquivalentSats(spamcoinSats: Double, rate: Double) -> Double? {
        guard spamcoinSats.isFinite, spamcoinSats >= 0, rate.isFinite, rate > 0 else { return nil }
        let value = self == .paySpamcoin ? spamcoinSats / rate : spamcoinSats * rate
        return value.isFinite ? value : nil
    }
}

public struct BridgeAvailability: Decodable, Sendable {
    public let open: Bool
    public let message: String?
    public let min_sat: Double?
    public let max_sat: Double?
}
public struct BridgeEstimate: Codable, Sendable {
    public let sat: Double
    public let estimate_sat: UInt64
    public let rate: Double
    public let spread: Double
    public let hash: String
    public let wait_s: Int?
    public func validate(target: BridgeInvoice) throws {
        guard hash == target.hash, sat.isFinite, abs(sat * 1000 - Double(target.msat)) < 0.01,
              estimate_sat > 0, rate.isFinite, rate > 0, spread.isFinite, spread >= 0 else { throw BridgeError.invalidQuote }
    }
}
public struct BridgeQuote: Codable, Equatable, Sendable {
    public let hold_invoice: String
    public let hash: String
    public let sat: Double
    public let pay_sat: UInt64
    public let rate: Double
    public let spread: Double
    public let expires_at: UInt64
    public let token: String

    public func validate(target: BridgeInvoice, direction: BridgeDirection = .paySpamcoin, now: Date = Date()) throws -> BridgeInvoice {
        let hold = try BridgeInvoice(hold_invoice)
        guard target.isXBT == direction.targetIsXBT, hold.isXBT != direction.targetIsXBT, hash == target.hash, hold.hash == target.hash,
              sat.isFinite, abs(sat * 1000 - Double(target.msat)) < 0.01,
              pay_sat > 0, pay_sat <= 2_100_000_000_000_000,
              (hold.msat + 999) / 1000 == pay_sat,
              rate.isFinite, rate > 0, spread.isFinite, spread >= 0,
              token.count == 32, token.allSatisfy(\.isHexDigit),
              expires_at <= hold.expiresAt, expires_at <= target.expiresAt else { throw BridgeError.invalidQuote }
        guard Double(expires_at) > now.timeIntervalSince1970 + 5 else { throw BridgeError.expired }
        return hold
    }
}
public struct BridgeSwapStatus: Decodable, Sendable {
    public let state: String
    public let preimage: String?
    public var failed: Bool { ["failed", "aborted", "expired"].contains(state) }
    public var title: String {
        switch state {
        case "quoted", "offered": return "Waiting for XBT payment"
        case "funded", "paid": return "XBT payment received"
        case "paying": return "Paying Spamcoin (BTC) invoice"
        case "settled": return "Spamcoin (BTC) invoice paid"
        case "failing", "aborting", "expiring": return "Releasing payment"
        case "failed", "aborted": return "Bridge payment did not complete"
        case "expired": return "Bridge quote expired"
        case "lost": return "Payment needs attention"
        default: return "Checking bridge payment"
        }
    }
}

public enum BridgeProofOfWork {
    public static func solve(challenge: String, bits: Int, hash: String) async throws -> String {
        guard (0...22).contains(bits), challenge.utf8.count <= 200, hash.count == 64, hash.allSatisfy(\.isHexDigit) else {
            throw BridgeError.unavailable("The bridge returned an unsupported verification challenge.")
        }
        let started = Date()
        for n in 0..<16_777_216 {
            if n % 4096 == 0 {
                try Task.checkCancellation()
                guard Date().timeIntervalSince(started) < 45 else { throw BridgeError.unavailable("Verification timed out. Try again.") }
            }
            let nonce = String(n, radix: 36)
            let digest = SHA256.hash(data: Data("\(challenge):\(hash):\(nonce)".utf8))
            var zeros = 0
            for byte in digest { zeros += byte.leadingZeroBitCount; if byte != 0 { break } }
            if zeros >= bits { return nonce }
        }
        throw BridgeError.unavailable("Verification timed out. Try again.")
    }
}

/// No node credentials, cookies, analytics or wallet balances are sent to the bridge.
/// The optional operator key is supplied at runtime; it is never bundled in the app.
public actor LightningBridge {
    private let session: URLSession
    private let key: String
    private var base: URL { URL(string: key.isEmpty ? "https://lightning.paperclip-xbt.xyz/bridge/api/" : "https://lightning.paperclip-xbt.xyz/bridge/private/v1/")! }
    public init(apiKey: String = "") {
        key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 35; config.timeoutIntervalForResource = 45
        session = URLSession(configuration: config, delegate: BridgeRedirectGuard(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    private struct Failure: Decodable { let error: String?; let wait_s: Int? }
    private func request<T: Decodable>(_ path: String, body: [String: Any]? = nil, timeout: TimeInterval? = nil) async throws -> T {
        guard let url = URL(string: path, relativeTo: base) else { throw BridgeError.invalidQuote }
        var request = URLRequest(url: url)
        if let timeout { request.timeoutInterval = timeout }
        if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, data.count < 65_536 else { throw BridgeError.invalidQuote }
        if let failure = try? JSONDecoder().decode(Failure.self, from: data), let code = failure.error {
            throw BridgeError.unavailable(Self.message(code, wait: failure.wait_s))
        }
        guard response.statusCode == 200 else { throw BridgeError.unavailable("Bridge unavailable (\(response.statusCode)). Try again shortly.") }
        return try JSONDecoder().decode(T.self, from: data)
    }
    public func availability(direction: BridgeDirection = .paySpamcoin) async throws -> BridgeAvailability { try await request("info?direction=\(direction.rawValue)", timeout: 8) }
    public func check(_ invoice: String, direction: BridgeDirection = .paySpamcoin) async throws -> BridgeEstimate {
        try await request("check", body: ["invoice": invoice, "direction": direction.rawValue])
    }
    public func quote(_ target: BridgeInvoice, direction: BridgeDirection = .paySpamcoin) async throws -> BridgeQuote {
        try target.validateTarget(direction: direction)
        var body: [String: Any] = ["invoice": target.text, "direction": direction.rawValue]
        if key.isEmpty {
            struct Challenge: Decodable { let challenge: String; let bits: Int }
            let challenge: Challenge = try await request("pow")
            // Actor work never runs on the UI's main actor. Bound CPU work and cancellation.
            let nonce = try await BridgeProofOfWork.solve(challenge: challenge.challenge, bits: challenge.bits, hash: target.hash)
            body["pow"] = ["challenge": challenge.challenge, "nonce": nonce]
        }
        return try await request("quote", body: body)
    }
    public func status(_ quote: BridgeQuote) async throws -> BridgeSwapStatus {
        guard quote.hash.count == 64, quote.hash.allSatisfy(\.isHexDigit), quote.token.count == 32, quote.token.allSatisfy(\.isHexDigit) else { throw BridgeError.invalidQuote }
        return try await request("swap/\(quote.hash)?t=\(quote.token)")
    }
    private static func message(_ code: String, wait: Int?) -> String {
        switch code {
        case "unauthorized": return "The private bridge API key was not accepted. Check Bridge connection settings."
        case "wait": return "This invoice already has a recent quote. Wait \(max(1, wait ?? 60)) seconds before requesting another."
        case "price_pause", "price_stale", "stale_price": return "The bridge is paused while pricing stabilizes. Try again shortly."
        case "limit", "daily_cap", "cap", "reserve", "insufficient_liquidity", "limits_unavailable": return "The bridge is at its liquidity or request limit. Try again later."
        case "too_small", "too_large": return "The invoice amount is outside the bridge’s current limits."
        case "expires_soon": return "Ask for an invoice with at least five minutes remaining."
        case "no_amount": return "Use a fixed-amount invoice for the receiving network."
        case "wrong_network", "is_xbt", "invalid_invoice", "checksum": return "Use a valid mainnet Lightning invoice for the receiving network."
        case "pow_missing", "pow_expired", "pow_used", "pow_invalid": return "Bridge verification expired. Request a new quote."
        default: return "The bridge cannot process this request right now. Check availability and try again."
        }
    }
}
private final class BridgeRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
