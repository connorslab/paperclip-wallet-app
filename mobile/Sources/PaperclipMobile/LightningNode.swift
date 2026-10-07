import Foundation
import Network
import Security
import CryptoKit

public enum LightningImplementation: String, Codable, CaseIterable, Sendable {
    case cln, lnd
    public var title: String { self == .cln ? "Core Lightning (BLAKE2b)" : "LND (BLAKE2b)" }
}

public struct LightningConnection: Codable, Equatable, Sendable {
    public var implementation: LightningImplementation = .cln
    public var endpoint = ""
    public var credential = ""
    public var certificateSHA256 = ""
    public var useTor = false
    public var torProxy = "builtin"
    public init() {}
    public func validate() throws {
        _ = try EndpointPolicy.validate(endpoint, tor: useTor, credentials: true)
        if useTor { try EndpointPolicy.validateTorProxy(torProxy) }
        guard !credential.isEmpty, !credential.contains(where: \.isNewline),
              credential.utf8.count < 16_384 else { throw ConnectionError.invalidCredential }
        if implementation == .lnd {
            guard credential.count.isMultiple(of: 2), credential.allSatisfy(\.isHexDigit) else { throw ConnectionError.invalidCredential }
        }
        if !certificateSHA256.isEmpty {
            guard certificateSHA256.count == 64, certificateSHA256.allSatisfy(\.isHexDigit) else { throw ConnectionError.invalidCredential }
        }
    }
}

private final class NodeSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let pin: String
    init(pin: String) { self.pin = pin.lowercased() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard !pin.isEmpty, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        guard let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        // A user-supplied exact certificate pin also supports a node's self-signed certificate.
        guard digest == pin else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

public actor LightningNode {
    private let connection: LightningConnection
    private let session: URLSession
    public init(connection: LightningConnection) throws {
        try connection.validate()
        self.connection = connection
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 90
        if connection.useTor {
            let proxy = try EndpointPolicy.proxy(connection.torProxy)
            if #available(iOS 17, macOS 14, *) {
                var settings = ProxyConfiguration(socksv5Proxy: .hostPort(host: .init(proxy.host!), port: .init(rawValue: UInt16(proxy.port!))!))
                settings.allowFailover = false
                configuration.proxyConfigurations = [settings]
            } else { throw ConnectionError.unsupportedTor }
        }
        session = URLSession(configuration: configuration, delegate: NodeSessionDelegate(pin: connection.certificateSHA256), delegateQueue: nil)
    }
    private func request(_ path: String, body: [String: Any]? = nil, query: [URLQueryItem] = []) async throws -> [String: Any] {
        var components = URLComponents(url: URL(string: connection.endpoint)!.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ConnectionError.response }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(connection.credential, forHTTPHeaderField: connection.implementation == .cln ? "Rune" : "Grpc-Metadata-macaroon")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ConnectionError.response }
        if (300..<400).contains(response.statusCode) { throw ConnectionError.redirect }
        guard (200..<300).contains(response.statusCode) else {
            let detail = [401, 403].contains(response.statusCode) ? " Check the node credential and permission for this method." : " Check that your node exposes this REST method."
            throw LightningNodeError(message: "Node rejected \(path) (HTTP \(response.statusCode))." + detail)
        }
        guard data.count < 8 * 1024 * 1024,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConnectionError.response }
        return json
    }
    public func info() async throws -> Data {
        let result = try await request("v1/getinfo", body: connection.implementation == .cln ? [:] : nil)
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
    }
    public func balance() async throws -> LightningBalance {
        let result = try await request(connection.implementation == .cln ? "v1/listpeerchannels" : "v1/channels",
            body: connection.implementation == .cln ? [:] : nil)
        return try LightningBalance.decode(JSONSerialization.data(withJSONObject: result), implementation: connection.implementation)
    }
    public func offer(amount: UInt64?, description: String) async throws -> String {
        guard connection.implementation == .cln else {
            throw LightningNodeError(message: "BOLT12 offers require Core Lightning with the offer RPC enabled.")
        }
        let result = try await request("v1/offer", body: Self.offerParameters(amount: amount, description: description))
        guard let offer = result["bolt12"] as? String, offer.hasPrefix("lno1"), result["active"] as? Bool == true else { throw ConnectionError.response }
        return offer
    }
    nonisolated static func offerParameters(amount: UInt64?, description: String) throws -> [String: Any] {
        guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, description.utf8.count <= 256,
              amount.map({ $0 > 0 && $0 <= UInt64.max / 1000 }) ?? true else { throw ConnectionError.response }
        return ["amount": amount.map { "\($0 * 1000)msat" } ?? "any",
            "description": description, "label": "paperclip-" + UUID().uuidString]
    }
    public func fetchOfferInvoice(_ offer: String, amountMsat: UInt64?) async throws -> String {
        guard connection.implementation == .cln else {
            throw LightningNodeError(message: "BOLT12 offer payments require a Core Lightning connection in this app.")
        }
        let result = try await request("v1/fetchinvoice", body: Self.fetchOfferParameters(offer, amountMsat: amountMsat))
        guard let invoice = result["invoice"] as? String, invoice.lowercased().hasPrefix("lni1"),
              !invoice.contains(where: \.isWhitespace) else { throw ConnectionError.response }
        return invoice
    }
    nonisolated static func fetchOfferParameters(_ offer: String, amountMsat: UInt64?) throws -> [String: Any] {
        guard offer.lowercased().hasPrefix("lno1"), !offer.contains(where: \.isWhitespace),
              amountMsat.map({ $0 > 0 }) ?? true else { throw ConnectionError.response }
        var fields: [String: Any] = ["offer": offer, "timeout": 45]
        if let amountMsat { fields["amount_msat"] = "\(amountMsat)msat" }
        return fields
    }
    public func invoice(amount: UInt64) async throws -> String {
        guard amount > 0, amount <= UInt64.max / 1000 else { throw ConnectionError.response }
        let cln = connection.implementation == .cln
        let result = try await request(cln ? "v1/invoice" : "v1/invoices", body: cln
            ? ["amount_msat": "\(amount * 1000)msat", "label": UUID().uuidString, "description": "Paperclip wallet"]
            : ["value": String(amount), "memo": "Paperclip wallet", "expiry": "3600"])
        guard let invoice = result[cln ? "bolt11" : "payment_request"] as? String else { throw ConnectionError.response }
        return invoice
    }
    public func decode(_ invoice: String) async throws -> Data {
        let result = try await request(connection.implementation == .cln ? "v1/decode" : "v1/payreq/\(invoice)",
            body: connection.implementation == .cln ? ["string": invoice] : nil)
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
    }
    // Call only after recording the pending invoice durably. Never automatically retry a payment.
    public func pay(_ invoice: String, maximumFee: UInt64) async throws -> Data {
        guard maximumFee <= UInt64.max / 1000 else { throw ConnectionError.response }
        let cln = connection.implementation == .cln
        let result = try await request(cln ? "v1/pay" : "v1/channels/transactions", body: cln
            ? ["bolt11": invoice, "maxfee": "\(maximumFee * 1000)msat", "retry_for": 30]
            : ["payment_request": invoice, "fee_limit": ["fixed": String(maximumFee)]])
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
    }
    public func payments(hash: String? = nil) async throws -> Data {
        if let hash { guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { throw ConnectionError.response } }
        if connection.implementation == .cln {
            let fields: [String: Any] = hash.map { ["payment_hash": $0] } ?? [:]
            return try JSONSerialization.data(withJSONObject: await request("v1/listpays", body: fields))
        }
        // Include failed and in-flight payments. Scan bounded pages backwards so
        // old attempts survive restart without repeatedly downloading all history.
        var offset = "0"
        var rows: [[String: Any]] = []
        for _ in 0..<20 {
            let result = try await request("v1/payments", query: [
                URLQueryItem(name: "include_incomplete", value: "true"),
                URLQueryItem(name: "reversed", value: "true"),
                URLQueryItem(name: "max_payments", value: "100"),
                URLQueryItem(name: "index_offset", value: offset),
            ])
            guard let page = result["payments"] as? [[String: Any]] else { throw ConnectionError.response }
            if let hash {
                rows += page.filter { ($0["payment_hash"] as? String)?.lowercased() == hash.lowercased() }
                if !rows.isEmpty { break }
            } else { rows += page; break }
            let next = (result["first_index_offset"] as? String) ?? (result["first_index_offset"] as? NSNumber)?.stringValue
            guard !page.isEmpty, let next, next != "0", next != offset else { break }
            offset = next
        }
        return try JSONSerialization.data(withJSONObject: ["payments": rows])
    }
}
