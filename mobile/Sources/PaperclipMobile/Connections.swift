import Foundation

public enum ChainBackend: String, Codable, CaseIterable, Sendable {
    case esplora, electrum, rpc
    public var title: String {
        switch self { case .esplora: return "Public / Esplora"; case .electrum: return "Electrum"; case .rpc: return "XBT Knots RPC" }
    }
}

public enum ConnectionError: LocalizedError {
    case invalidEndpoint, onionNeedsTor, insecureCredentials, invalidProxy, invalidCredential, response, redirect, unsupportedTor
    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Enter a valid endpoint without embedded credentials, a query, or a fragment."
        case .onionNeedsTor: return "Enable Tor before connecting to an onion endpoint."
        case .insecureCredentials: return "Use HTTPS for credentials, or an onion endpoint through Tor."
        case .invalidProxy: return "Enter a socks5h://host:port Tor proxy. DNS must resolve through Tor."
        case .invalidCredential: return "Enter the node credential in the required format."
        case .response: return "The node returned an invalid response."
        case .redirect: return "The endpoint redirected the request. Use its final URL."
        case .unsupportedTor: return "This OS version does not support the required Tor proxy configuration."
        }
    }
}

public struct ConnectionFieldError: LocalizedError {
    public let field: String
    public let reason: String
    public var errorDescription: String? { "\(field): \(reason)" }
}

private func validateField(_ field: String, hint: String, _ validate: () throws -> Void) throws {
    do { try validate() }
    catch {
        throw ConnectionFieldError(field: field, reason: "\(error.localizedDescription) \(hint)")
    }
}

public struct WalletConnection: Codable, Equatable, Sendable {
    public var arkRPC: ArkRPCConnection? = nil
    public var backend: ChainBackend = .electrum
    public var endpoint = "ssl://pool.paperclippool.xyz:50002"
    public var certificateSHA256 = ""
    public var arkServer = "https://ark.paperclippool.xyz"
    public var username = ""
    public var password = ""
    public var useTor = false
    public var torProxy = "socks5h://127.0.0.1:9050"
    public init() {}
    public func validate() throws {
        if backend == .rpc && (username.isEmpty || password.isEmpty) { throw ConnectionError.invalidCredential }
        try arkRPC?.validate()
        try validateField("Ark server", hint: "Use https://ark.paperclippool.xyz or your server's full URL.") {
            _ = try EndpointPolicy.validate(arkServer, tor: arkRPC?.useTor ?? useTor)
        }
        let hint = backend == .electrum
            ? "Use tcp://192.168.1.10:50001 for plain Electrum, or ssl://host:50002 for TLS. HTTP is for RPC, not Electrum."
            : "Include http:// or https:// and the node's port, for example http://192.168.1.10:8332. Enter credentials in their separate fields."
        try validateField("On-chain endpoint", hint: hint) {
            _ = try EndpointPolicy.validate(endpoint, tor: useTor, electrum: backend == .electrum,
                credentials: backend == .rpc && (!username.isEmpty || !password.isEmpty), allowHTTP: true)
        }
        if useTor { _ = try EndpointPolicy.proxy(torProxy) }
        if !certificateSHA256.isEmpty {
            guard certificateSHA256.count == 64, certificateSHA256.allSatisfy(\.isHexDigit) else { throw ConnectionError.invalidCredential }
        }
    }
}

/// Separate relay-policy/package backend; credentials remain in device Keychain.
public struct ArkRPCConnection: Codable, Equatable, Sendable {
    public var endpoint = ""
    public var username = ""
    public var password = ""
    public var useTor = false
    public var torProxy = "socks5h://127.0.0.1:9050"
    public init() {}
    private enum CodingKeys: String, CodingKey { case endpoint, username, password, useTor, torProxy }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try values.decode(String.self, forKey: .endpoint)
        username = try values.decode(String.self, forKey: .username)
        password = try values.decode(String.self, forKey: .password)
        useTor = try values.decodeIfPresent(Bool.self, forKey: .useTor) ?? false
        torProxy = try values.decodeIfPresent(String.self, forKey: .torProxy) ?? "socks5h://127.0.0.1:9050"
    }
    public func validate() throws {
        guard !username.isEmpty, !password.isEmpty else { throw ConnectionError.invalidCredential }
        try validateField("Ark RPC endpoint", hint: "Include http:// or https:// and the RPC port. Enter credentials in their separate fields.") {
            _ = try EndpointPolicy.validate(endpoint, tor: useTor, credentials: true, allowHTTP: true)
        }
        if useTor { _ = try EndpointPolicy.proxy(torProxy) }
    }
}

public enum EndpointPolicy {
    public static func validate(_ text: String, tor: Bool, electrum: Bool = false, credentials: Bool = false, allowHTTP: Bool = false) throws -> URL {
        guard text == text.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text), let host = url.host, !host.isEmpty,
              let scheme = url.scheme?.lowercased(),
              (electrum ? ["ssl", "tcp"] : ["https", "http"]).contains(scheme),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true else { throw ConnectionError.invalidEndpoint }
        let onion = host.lowercased().hasSuffix(".onion")
        if onion && !tor { throw ConnectionError.onionNeedsTor }
        if electrum && (url.port == nil || (!url.path.isEmpty && url.path != "/")) { throw ConnectionError.invalidEndpoint }
        if credentials && scheme != "https" && !(allowHTTP && scheme == "http") && !(onion && tor) { throw ConnectionError.insecureCredentials }
        return url
    }
    public static func proxy(_ text: String) throws -> URL {
        guard let url = URL(string: text), url.scheme == "socks5h", let host = url.host, !host.isEmpty,
              let port = url.port, (1...65535).contains(port), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty,
              !host.lowercased().hasSuffix(".onion") else { throw ConnectionError.invalidProxy }
        return url
    }
}

/// All words must be entered without the phrase visible before wallet creation.
public enum SeedVerification {
    public static func matches(phrase: String, confirmation: String) -> Bool {
        let normalize: (String) -> [Substring] = { $0.lowercased().split(whereSeparator: \.isWhitespace) }
        let words = normalize(phrase)
        return [12, 24].contains(words.count) && words == normalize(confirmation)
    }
}
