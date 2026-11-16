import Foundation
import Network

/// A separate remote Jam wallet. Paperclip never sends its own seed to Jam.
public struct JoinBlaketConnection: Codable, Equatable, Sendable {
    public var endpoint = ""
    public var certificateSHA256 = ""
    public var useTor = false
    public var torProxy = "builtin"
    public init() {}
    public func validate() throws {
        let url = try EndpointPolicy.validate(endpoint, tor: useTor, credentials: true)
        if useTor { try EndpointPolicy.validateTorProxy(torProxy) }
        if !certificateSHA256.isEmpty {
            let pins = certificateSHA256.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard url.scheme == "https", (1...4).contains(pins.count), pins.allSatisfy({ pin in
                pin.utf8.count == 64 && pin.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
            }) else {
                throw ConnectionError.invalidCredential
            }
        }
    }
}

public enum JoinBlaketError: LocalizedError {
    case sessionExpired, invalidResponse, wrongWallet, invalidBondMonth, requestFailed(Int)
    public var errorDescription: String? {
        switch self {
        case .sessionExpired: return "Unlock your JoinBlaket wallet again to continue."
        case .invalidResponse: return "JoinBlaket returned an unreadable response. Refresh before continuing."
        case .wrongWallet: return "The active JoinBlaket wallet changed. Reconnect before continuing."
        case .invalidBondMonth: return "Choose a future month in YYYY-MM format, before 2100. Bonds unlock on its first day at 00:00 UTC."
        case .requestFailed(let code): return "JoinBlaket request failed (HTTP \(code)). Check its current status before retrying an action."
        }
    }
}

public enum JoinBlaketBond {
    public static func validate(month: String, now: Date = Date()) throws {
        let bytes = Array(month.utf8)
        guard bytes.count == 7, bytes[4] == 45,
              bytes.enumerated().allSatisfy({ $0.offset == 4 || (48...57).contains($0.element) }),
              let year = Int(month.prefix(4)), (2020...2099).contains(year),
              let number = Int(month.suffix(2)), (1...12).contains(number) else { throw JoinBlaketError.invalidBondMonth }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: number, day: 1)), date > now else { throw JoinBlaketError.invalidBondMonth }
    }
}

public struct JoinBlaketSession: Decodable, Sendable {
    public let session: Bool
    public let maker_running: Bool
    public let coinjoin_in_process: Bool
    public let wallet_name: String
    public let rescanning: Bool
}

public struct JoinBlaketJar: Decodable, Identifiable, Sendable {
    public let id: UInt8
    public let name: String
    public let total_sat: UInt64
    public let confirmed_sat: UInt64
    public let pending_sat: UInt64
    public let frozen_sat: UInt64
    public let bond_sat: UInt64
}

/// Setup guidance, not a guarantee of market selection or an active bond proof.
public struct JoinBlaketMakerReadiness: Sendable {
    public let terms: Bool
    public let funds: Bool
    public let bond: Bool
    public let server: Bool
    public let fresh: Bool
    public var canStart: Bool { terms && funds && bond && server && fresh }
    public init(minimum: String, fee: String, jars: [JoinBlaketJar], session: JoinBlaketSession?, needsRefresh: Bool) {
        func sats(_ value: String) -> UInt64? {
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return UInt64(value)
        }
        let minimum = sats(minimum) ?? 0, fee = sats(fee)
        let validMinimum = (27_300...2_100_000_000_000_000).contains(minimum)
        terms = validMinimum && (fee.map { $0 < minimum } ?? false)
        funds = validMinimum && jars.contains { $0.confirmed_sat >= minimum }
        bond = jars.contains { $0.bond_sat > 0 }
        server = session?.session == true && session?.maker_running == false && session?.rescanning == false && session?.coinjoin_in_process == false
        fresh = session != nil && !needsRefresh
    }
}

/// Deliberately excludes passwords and bearer tokens from Codable/debug output.
public struct JoinBlaketAuthorization: Sendable, CustomStringConvertible {
    public let wallet: String
    fileprivate let token: String
    public var description: String { "JoinBlaket authorization (redacted)" }
    public init(wallet: String, token: String) throws {
        guard !wallet.isEmpty, wallet.utf8.count <= 256,
              !token.isEmpty, token.utf8.count < 16_384,
              token.utf8.allSatisfy({ (33...126).contains($0) }) else { throw ConnectionError.invalidCredential }
        self.wallet = wallet; self.token = token
    }
}

/// Remote Jam transport uses the same certificate/Tor policy as node connections.
/// No automatic request replay: several GET endpoints also mutate wallet state.
public actor JoinBlaketClient {
    private let connection: JoinBlaketConnection
    private let session: URLSession
    private let delegate: NodeSessionDelegate

    public init(connection: JoinBlaketConnection) throws {
        try self.init(connection: connection, configuration: .ephemeral)
    }
    init(connection: JoinBlaketConnection, configuration: URLSessionConfiguration) throws {
        try connection.validate()
        self.connection = connection
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        if connection.useTor {
            let proxy = try EndpointPolicy.proxy(connection.torProxy)
            if #available(iOS 17, macOS 14, *) {
                var settings = ProxyConfiguration(socksv5Proxy: .hostPort(host: .init(proxy.host!), port: .init(rawValue: UInt16(proxy.port!))!))
                settings.allowFailover = false
                configuration.proxyConfigurations = [settings]
            } else { throw ConnectionError.unsupportedTor }
        }
        delegate = NodeSessionDelegate(pin: connection.certificateSHA256, diagnostics: nil)
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    private func request(_ components: [String], authorization: JoinBlaketAuthorization? = nil,
                         body: [String: String]? = nil) async throws -> Data {
        var url = try EndpointPolicy.validate(connection.endpoint, tor: connection.useTor, credentials: true)
        for component in ["api", "v1"] + components {
            // URL path components must not be able to replace the origin or escape the wallet.
            guard !component.isEmpty, !component.contains("/"), !component.contains("\\"),
                  component != ".", component != ".." else { throw JoinBlaketError.invalidResponse }
            url.appendPathComponent(component)
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authorization { request.setValue("Bearer " + authorization.token, forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw JoinBlaketError.invalidResponse }
            guard http.statusCode != 401 else { throw JoinBlaketError.sessionExpired }
            guard (200..<300).contains(http.statusCode) else { throw JoinBlaketError.requestFailed(http.statusCode) }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 4 * 1024 * 1024 else { throw JoinBlaketError.invalidResponse }
                data.append(byte)
            }
            return data
        } catch {
            if let failure = delegate.failure { throw failure }
            throw error
        }
    }

    public func wallets() async throws -> [String] {
        struct Response: Decodable { let wallets: [String] }
        return try JSONDecoder().decode(Response.self, from: await request(["wallet", "all"])).wallets
    }
    public func unlock(wallet: String, password: String, passphrase: String = "") async throws -> JoinBlaketAuthorization {
        struct Response: Decodable { let walletname: String; let token: String }
        var body = ["password": password]
        if !passphrase.isEmpty { body["bip39_passphrase"] = passphrase }
        let response = try JSONDecoder().decode(Response.self, from: await request(["wallet", wallet, "unlock"], body: body))
        guard response.walletname == wallet else { throw JoinBlaketError.wrongWallet }
        return try JoinBlaketAuthorization(wallet: wallet, token: response.token)
    }
    public func status(_ authorization: JoinBlaketAuthorization) async throws -> JoinBlaketSession {
        let state = try JSONDecoder().decode(JoinBlaketSession.self, from: await request(["session"], authorization: authorization))
        guard state.session, state.wallet_name == authorization.wallet else { throw JoinBlaketError.wrongWallet }
        return state
    }
    /// Feed this response into the shared Rust jar validator before presenting balances.
    public func coins(_ authorization: JoinBlaketAuthorization) async throws -> Data {
        _ = try await status(authorization)
        return try await request(["wallet", authorization.wallet, "utxos"], authorization: authorization)
    }
    public func receiveAddress(jar: UInt8, authorization: JoinBlaketAuthorization) async throws -> String {
        guard jar < 5 else { throw JoinBlaketError.invalidResponse }
        struct Response: Decodable { let address: String }
        return try JSONDecoder().decode(Response.self, from: await request(["wallet", authorization.wallet, "address", "new", String(jar)], authorization: authorization)).address
    }
    /// Registers a deterministic bond address. Never funds it or starts a maker.
    public func bondAddress(month: String, authorization: JoinBlaketAuthorization) async throws -> String {
        try JoinBlaketBond.validate(month: month)
        let current = try await status(authorization)
        guard !current.coinjoin_in_process, !current.rescanning else { throw JoinBlaketError.invalidResponse }
        try JoinBlaketBond.validate(month: month)
        struct Response: Decodable { let address: String }
        let address = try JSONDecoder().decode(Response.self, from: await request(["wallet", authorization.wallet, "address", "timelock", "new", month], authorization: authorization)).address
        guard !address.isEmpty, address.utf8.count <= 128, !address.contains(where: { $0.isWhitespace }) else { throw JoinBlaketError.invalidResponse }
        return address
    }
    /// Starts a remote service only after the user reviews its explicit terms.
    /// A timeout means reconcile status; it never causes a second start request.
    public func startMaker(minimumSat: UInt64, feeSat: UInt64, authorization: JoinBlaketAuthorization) async throws {
        guard minimumSat >= 27_300, minimumSat <= 2_100_000_000_000_000, feeSat < minimumSat else { throw JoinBlaketError.invalidResponse }
        let current = try await status(authorization)
        guard !current.maker_running, !current.coinjoin_in_process, !current.rescanning else { throw JoinBlaketError.invalidResponse }
        _ = try await request(["wallet", authorization.wallet, "maker", "start"], authorization: authorization,
                              body: ["txfee": "0", "cjfee_a": String(feeSat), "cjfee_r": "0", "ordertype": "sw0absoffer", "minsize": String(minimumSat)])
    }
    public func stopMaker(authorization: JoinBlaketAuthorization) async throws {
        _ = try await request(["wallet", authorization.wallet, "maker", "stop"], authorization: authorization)
    }
}
