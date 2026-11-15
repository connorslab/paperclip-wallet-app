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
        if implementation == .cln, !credential.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 95, 61].contains($0)
        }) {
            throw ConnectionFieldError(field: "Access rune", reason: "Paste only the base64url rune from Core Lightning. A connection URL, quotes, or other characters cannot be used as a rune.")
        }
        if implementation == .lnd {
            guard credential.count.isMultiple(of: 2), credential.allSatisfy(\.isHexDigit) else { throw ConnectionError.invalidCredential }
        }
        if !certificateSHA256.isEmpty {
            let pins = certificateSHA256.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard (1...4).contains(pins.count), pins.allSatisfy({ $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) } }) else {
                throw ConnectionFieldError(field: "Certificate fingerprints", reason: "Enter up to four SHA256 fingerprints, each 64 hexadecimal characters, separated by commas.")
            }
        }
    }
}

public enum LightningTransportEvent: Sendable {
    case requestStarted, tlsDefaultTrust, tlsPinMatched, tlsPinRejected, tlsTrustMissing
    case httpStatus(Int), transportError(Int)
    case presentedCertificateSHA256(String)
}

public enum LightningTLSFailure: LocalizedError, Equatable {
    case pinMismatch, missingTrust
    public var errorDescription: String? {
        switch self {
        case .pinMismatch: return "The node’s TLS certificate does not match any saved SHA256 fingerprint. Verify the certificate in your node settings and update the fingerprint before retrying."
        case .missingTrust: return "The node did not provide a verifiable TLS certificate. Check its HTTPS REST configuration."
        }
    }
}

final class NodeSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let pin: String
    let pins: Set<String>
    private let failureLock = NSLock()
    private var tlsFailure: LightningTLSFailure?
    var failure: LightningTLSFailure? {
        failureLock.lock(); defer { failureLock.unlock() }; return tlsFailure
    }
    private func reject(_ failure: LightningTLSFailure) {
        failureLock.lock(); defer { failureLock.unlock() }; tlsFailure = failure
    }
    let diagnostics: (@Sendable (LightningTransportEvent) -> Void)?
    init(pin: String, diagnostics: (@Sendable (LightningTransportEvent) -> Void)?) {
        self.pin = pin.lowercased()
        self.pins = Set(pin.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        self.diagnostics = diagnostics
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard !pin.isEmpty, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            diagnostics?(.tlsDefaultTrust)
            completionHandler(.performDefaultHandling, nil); return
        }
        guard let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            reject(.missingTrust)
            diagnostics?(.tlsTrustMissing)
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        diagnostics?(.presentedCertificateSHA256(digest))
        // A user-supplied exact certificate pin also supports a node's self-signed certificate.
        guard pins.contains(digest) else { reject(.pinMismatch); diagnostics?(.tlsPinRejected); completionHandler(.cancelAuthenticationChallenge, nil); return }
        diagnostics?(.tlsPinMatched)
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

// Retry only observations. POST is also used for read-only CLN RPCs.
// Invoice/offer creation and payment submission must never be replayed here.
enum LightningRequestPolicy {
    static let requestTimeout: TimeInterval = 60
    static let resourceTimeout: TimeInterval = 90
    static func isReadOnly(_ path: String) -> Bool {
        ["v1/getinfo", "v1/channels", "v1/listpeerchannels", "v1/listpays",
         "v1/payments", "v1/listinvoices", "v1/decode", "v2/offers/decode"].contains(path)
        || ["v1/invoice/", "v1/payreq/", "v2/router/track/"].contains { path.hasPrefix($0) }
    }
    static func canRetry(_ error: Error, path: String) -> Bool {
        guard isReadOnly(path), let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code)
    }
}

public actor LightningNode {
    private let connection: LightningConnection
    private let session: URLSession
    private let diagnostics: (@Sendable (LightningTransportEvent) -> Void)?
    public init(connection: LightningConnection, diagnostics: (@Sendable (LightningTransportEvent) -> Void)? = nil) throws {
        try self.init(connection: connection, configuration: .ephemeral, diagnostics: diagnostics)
    }
    init(connection: LightningConnection, configuration: URLSessionConfiguration, diagnostics: (@Sendable (LightningTransportEvent) -> Void)? = nil) throws {
        self.diagnostics = diagnostics
        try connection.validate()
        self.connection = connection
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = LightningRequestPolicy.requestTimeout
        configuration.timeoutIntervalForResource = LightningRequestPolicy.resourceTimeout
        if connection.useTor {
            let proxy = try EndpointPolicy.proxy(connection.torProxy)
            if #available(iOS 17, macOS 14, *) {
                var settings = ProxyConfiguration(socksv5Proxy: .hostPort(host: .init(proxy.host!), port: .init(rawValue: UInt16(proxy.port!))!))
                settings.allowFailover = false
                configuration.proxyConfigurations = [settings]
            } else { throw ConnectionError.unsupportedTor }
        }
        session = URLSession(configuration: configuration, delegate: NodeSessionDelegate(pin: connection.certificateSHA256, diagnostics: diagnostics), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    private func request(_ path: String, body: [String: Any]? = nil, query: [URLQueryItem] = []) async throws -> [String: Any] {
        var components = URLComponents(url: URL(string: connection.endpoint)!.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ConnectionError.response }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(connection.credential, forHTTPHeaderField: connection.implementation == .cln ? "Rune" : "Grpc-Metadata-macaroon")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        diagnostics?(.requestStarted)
        let (data, response) = try await response(for: request, path: path)
        guard let response = response as? HTTPURLResponse else { throw ConnectionError.response }
        diagnostics?(.httpStatus(response.statusCode))
        if (300..<400).contains(response.statusCode) { throw ConnectionError.redirect }
        guard (200..<300).contains(response.statusCode) else {
            if path.hasPrefix("v2/offers"), [404, 501].contains(response.statusCode) {
                throw LightningNodeError(message: "This node does not expose XBT LND’s BOLT12 offers API. Check its version and offersrpc support.")
            }
            if response.statusCode == 401 {
                let credential = connection.implementation == .cln ? "Core Lightning rune" : "LND macaroon"
                throw LightningNodeError(message: "The node rejected the \(credential) (HTTP 401). Copy a valid credential from this node’s settings and verify again.")
            }
            if response.statusCode == 403 {
                throw LightningNodeError(message: "This credential does not permit the requested node operation (HTTP 403). Check its permissions in your node settings.")
            }
            if response.statusCode == 404 {
                throw LightningNodeError(message: "This REST method was not found (HTTP 404). Check the node software, REST address, and port; the dashboard address may be different.")
            }
            throw LightningNodeError(message: "Node request failed (HTTP \(response.statusCode)). Check the node’s service status. Check any pending payment before trying another send.")
        }
        guard data.count < 8 * 1024 * 1024,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConnectionError.response }
        return json
    }
    private func response(for request: URLRequest, path: String) async throws -> (Data, URLResponse) {
        for attempt in 0...1 {
            try Task.checkCancellation()
            let delegate = NodeSessionDelegate(pin: connection.certificateSHA256, diagnostics: diagnostics)
            do { return try await session.data(for: request, delegate: delegate) }
            catch {
                diagnostics?(.transportError((error as NSError).code))
                if let failure = delegate.failure { throw failure }
                guard attempt == 0, LightningRequestPolicy.canRetry(error, path: path) else { throw error }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        throw ConnectionError.response
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
        let cln = connection.implementation == .cln
        var fields = try Self.offerParameters(amount: amount, description: description)
        if !cln { fields.removeValue(forKey: "amount"); fields["amount_msat"] = String((amount ?? 0) * 1000) }
        let response = try await request(cln ? "v1/offer" : "v2/offers", body: fields)
        let result = cln ? response : (response["offer"] as? [String: Any] ?? [:])
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
        let cln = connection.implementation == .cln
        var fields = try Self.fetchOfferParameters(offer, amountMsat: amountMsat)
        if !cln {
            fields.removeValue(forKey: "timeout"); fields["timeout_seconds"] = 30
            fields["amount_msat"] = amountMsat.map(String.init)
        }
        let result = try await request(cln ? "v1/fetchinvoice" : "v2/offers/fetchinvoice", body: fields)
        guard let invoice = result[cln ? "invoice" : "bolt12"] as? String, invoice.lowercased().hasPrefix("lni1"),
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
    public func receivedInvoice(_ invoice: BridgeInvoice) async throws -> LightningInvoiceReceipt {
        let cln = connection.implementation == .cln
        let result = try await request(cln ? "v1/listinvoices" : "v1/invoice/\(invoice.hash)",
            body: cln ? ["payment_hash": invoice.hash] : nil)
        return try LightningInvoiceReceipt.decode(JSONSerialization.data(withJSONObject: result),
            implementation: connection.implementation, invoice: invoice)
    }
    public func decode(_ invoice: String) async throws -> Data {
        let cln = connection.implementation == .cln
        let bolt12 = ["lno1", "lni1"].contains { invoice.lowercased().hasPrefix($0) }
        let path = cln ? "v1/decode" : bolt12 ? "v2/offers/decode" : "v1/payreq/\(invoice)"
        var result = try await request(path, body: cln ? ["string": invoice] : bolt12 ? ["bolt12": invoice] : nil)
        if !cln, invoice.lowercased().hasPrefix("lni1"), var fields = result["invoice"] as? [String: Any] {
            let expiry = try LNDBolt12.relativeExpiry(invoice)
            let reported = try LNDBolt12.number(fields["relative_expiry"] ?? 0)
            guard reported == expiry || (reported == 0 && expiry == 7200) else { throw ConnectionError.response }
            fields["relative_expiry"] = String(expiry); result["invoice"] = fields
        }
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
    }
    // Read the first status update, then close only the HTTP stream. LND keeps
    // routing because cancelable is false; the journal tracks it without resending.
    private func lndStream(_ path: String, body: [String: Any]? = nil, query: [URLQueryItem] = []) async throws -> Data {
        for attempt in 0...1 {
            try Task.checkCancellation()
            do { return try await lndStreamOnce(path, body: body, query: query) }
            catch {
                guard attempt == 0, LightningRequestPolicy.canRetry(error, path: path) else { throw error }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        throw ConnectionError.response
    }
    private func lndStreamOnce(_ path: String, body: [String: Any]?, query: [URLQueryItem]) async throws -> Data {
        var components = URLComponents(url: URL(string: connection.endpoint)!.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw ConnectionError.response }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.timeoutInterval = LightningRequestPolicy.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(connection.credential, forHTTPHeaderField: "Grpc-Metadata-macaroon")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let delegate = NodeSessionDelegate(pin: connection.certificateSHA256, diagnostics: diagnostics)
        let bytes: URLSession.AsyncBytes, response: URLResponse
        do { (bytes, response) = try await session.bytes(for: request, delegate: delegate) }
        catch {
            if let failure = delegate.failure { throw failure }
            throw error
        }
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw ConnectionError.response }
        if (300..<400).contains(response.statusCode) { throw ConnectionError.redirect }
        if [401, 403, 405].contains(response.statusCode) || (body != nil && response.statusCode == 404) {
            // HTTP 404 alone is not proof that a payment hash is absent.
            throw LNDStreamError(code: response.statusCode == 401 ? 16 : response.statusCode == 403 ? 7 : 12,
                message: "Node rejected this REST method (HTTP \(response.statusCode)). Check router RPC support and macaroon permissions.")
        }
        func decodeLine(_ data: Data) throws -> Data {
            let result = try LNDStreamResponse.decode(data)
            guard (200..<300).contains(response.statusCode) else { throw ConnectionError.response }
            return result
        }
        var line = Data()
        for try await byte in bytes {
            if byte == 10 {
                if line.isEmpty { continue }
                return try decodeLine(line)
            }
            guard line.count < 256 * 1024 else { throw ConnectionError.response }
            line.append(byte)
        }
        guard !line.isEmpty else { throw ConnectionError.response }
        return try decodeLine(line)
    }
    // Call only after recording the pending invoice durably. Never automatically retry a payment.
    public func pay(_ invoice: String, maximumFee: UInt64) async throws -> Data {
        guard maximumFee <= UInt64.max / 1000 else { throw ConnectionError.response }
        if connection.implementation == .lnd {
            if invoice.lowercased().hasPrefix("lni1") {
                try Self.validateLNDOfferFee(maximumFee)
                let result = try await request("v2/offers/pay", body: ["invoice": invoice,
                    "fee_limit_msat": String(maximumFee * 1000), "timeout_seconds": 30])
                return try LNDBolt12.paymentResult(result, invoice: invoice)
            }
            return try await lndStream("v2/router/send", body: ["payment_request": invoice,
                "fee_limit_sat": String(maximumFee), "timeout_seconds": 30,
                "no_inflight_updates": false, "cancelable": false])
        }
        let result = try await request("v1/pay", body: ["bolt11": invoice, "maxfee": "\(maximumFee * 1000)msat", "retry_for": 30])
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
    }
    public nonisolated static func validateLNDOfferFee(_ sats: UInt64) throws {
        // offersrpc interprets zero as its default fee budget, not a zero-fee cap.
        guard sats > 0, sats <= UInt64.max / 1000 else {
            throw LightningNodeError(message: "XBT LND BOLT12 payments require a positive maximum routing fee. A zero value would use the node’s default fee limit.")
        }
    }
    public func trackPayment(hash: String) async throws -> Data {
        guard connection.implementation == .lnd, hash.count == 64, hash.allSatisfy(\.isHexDigit) else { throw ConnectionError.response }
        var raw = Data()
        var index = hash.startIndex
        while index < hash.endIndex {
            let end = hash.index(index, offsetBy: 2)
            guard let byte = UInt8(hash[index..<end], radix: 16) else { throw ConnectionError.response }
            raw.append(byte); index = end
        }
        let encoded = raw.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return try await lndStream("v2/router/track/" + encoded, query: [URLQueryItem(name: "no_inflight_updates", value: "false")])
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
