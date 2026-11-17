import Foundation
import Network

/// A scoped host grant, not a main-wallet or Jam password. Store only in Keychain.
public struct JoinBlaketPairing: Decodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let kind: String
    let scope: String
    public let endpoint: String
    public let wallet: String
    fileprivate let token: String
    let expires: Int64
    let certificate_sha256: String
    public var description: String { "Jars pairing (redacted)" }
    public var debugDescription: String { description }
    public init(text: String, now: Date = Date()) throws {
        guard text.utf8.count <= 4096, text.hasPrefix("paperclip-jars:") else { throw ConnectionError.invalidCredential }
        var encoded = String(text.dropFirst("paperclip-jars:".count)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { throw ConnectionError.invalidCredential }
        self = try JSONDecoder().decode(Self.self, from: data)
        guard kind == "paperclip-jars-v1", scope == "jars_manage_v1", expires > Int64(now.timeIntervalSince1970),
              token.hasPrefix("pj1_"), JoinBlaketPayment.validID(String(token.dropFirst(4))),
              !wallet.isEmpty, wallet.utf8.count <= 256, !wallet.contains("/"), !wallet.contains("\\"), wallet != ".", wallet != ".." else { throw ConnectionError.invalidCredential }
        try connection.validate()
    }
    public var connection: JoinBlaketConnection {
        var value = JoinBlaketConnection(); value.endpoint = endpoint; value.certificateSHA256 = certificate_sha256
        value.useTor = URL(string: endpoint)?.host?.lowercased().hasSuffix(".onion") == true
        return value
    }
    public func authorization() throws -> JoinBlaketAuthorization { try .init(wallet: wallet, token: token) }
    fileprivate func request(_ components: [String], body: [String: String]?) throws -> [String: Any] {
        guard expires > Int64(Date().timeIntervalSince1970) else { throw JoinBlaketError.sessionExpired }
        var fields: [String: Any] = ["wallet": wallet]
        let path = components.joined(separator: "/"), prefix = "wallet/\(wallet)/"
        if components.count == 3 && components.prefix(2).elementsEqual(["paperclip", "market"]), body == nil, let amount = UInt64(components[2]), (27_300...2_100_000_000_000_000).contains(amount) {
            fields["operation"] = "market"; fields["comparison_sat"] = amount
        } else if path == "session" && body == nil { fields["operation"] = "status" }
        else if path == prefix + "utxos" && body == nil { fields["operation"] = "coins" }
        else if components.count == 5 && components.prefix(4).elementsEqual(["wallet", wallet, "address", "new"]), body == nil, let jar = UInt8(components[4]), jar < 5 {
            fields["operation"] = "address"; fields["jar"] = jar
        } else if components.count == 6 && components.prefix(5).elementsEqual(["wallet", wallet, "address", "timelock", "new"]), body == nil {
            try JoinBlaketBond.validate(month: components[5]); fields["operation"] = "bond_address"; fields["lock_month"] = components[5]
        } else if path == prefix + "maker/start", let body, let minimum = UInt64(body["minsize"] ?? ""), let rate = body["cjfee_r"], JoinBlaketMakerFee.rates.contains(rate), body["txfee"] == "0", body["cjfee_a"] == "0", body["ordertype"] == "sw0reloffer" {
            fields["operation"] = "start_maker"; fields["minimum_sat"] = minimum; fields["relative_fee"] = rate
        } else if path == prefix + "maker/start", let body, let minimum = UInt64(body["minsize"] ?? ""), let fee = UInt64(body["cjfee_a"] ?? ""), body["txfee"] == "0", body["cjfee_r"] == "0", body["ordertype"] == "sw0absoffer" {
            fields["operation"] = "start_maker"; fields["minimum_sat"] = minimum; fields["fee_sat"] = fee
        } else if path == prefix + "maker/stop" && body == nil { fields["operation"] = "stop_maker" }
        else if path == prefix + "paperclip/payments" && body == nil { fields["operation"] = "payments" }
        else if components.count == 5 && components.prefix(4).elementsEqual(["wallet", wallet, "paperclip", "payments"]), body == nil, JoinBlaketPayment.validID(components[4]) {
            fields["operation"] = "check_payment"; fields["payment_id"] = components[4]
        } else { throw JoinBlaketError.invalidResponse }
        return fields
    }
}

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
    case sessionExpired, pairingUnavailable, invalidResponse, wrongWallet, invalidBondMonth, requestFailed(Int)
    public var errorDescription: String? {
        switch self {
        case .sessionExpired: return "Unlock your JoinBlaket wallet again to continue."
        case .pairingUnavailable: return "Check Jars on your Paperclip host. If Jam locked or restarted, unlock it there and create a new pairing. Check status before retrying an action."
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

/// Saved server state only. Node acceptance is not confirmation, and observation
/// must never turn into another send. Unknown future states fail closed.
public struct JoinBlaketPayment: Decodable, Identifiable, Sendable {
    public enum State: String, Decodable, Sendable {
        case preparing, prepared, submitting, unknown, submitted, cancelled
        public var label: String {
            switch self {
            case .preparing: return "Review incomplete"
            case .prepared: return "Review saved"
            case .submitting, .unknown: return "Status unknown"
            case .submitted: return "Submitted"
            case .cancelled: return "Cancelled"
            }
        }
    }
    public struct Quote: Decodable, Equatable, Sendable {
        public let wallet: String
        public let jar: UInt8
        public let purpose: String
        public let destination: String
        public let txid: String
        public let amount_sat: UInt64
        public let fee_sat: UInt64
        public let total_sat: UInt64
    }
    public let id: String
    public let state: State
    public let quote: Quote?
    public var canDiscard: Bool { state == .preparing || state == .prepared }
    public var needsCheck: Bool { state == .submitting || state == .unknown }
    static func validID(_ id: String) -> Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    func validate(wallet: String) throws {
        guard Self.validID(id) else { throw JoinBlaketError.invalidResponse }
        guard let quote else {
            guard state == .preparing || state == .cancelled else { throw JoinBlaketError.invalidResponse }
            return
        }
        guard quote.wallet == wallet else { throw JoinBlaketError.wrongWallet }
        guard quote.jar < 5, ["send", "fund_bond", "withdraw_bond"].contains(quote.purpose),
              Self.validID(quote.txid), (14...90).contains(quote.destination.utf8.count),
              quote.destination.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
              quote.amount_sat > 0,
              [quote.amount_sat, quote.fee_sat, quote.total_sat].allSatisfy({ $0 <= 2_100_000_000_000_000 }),
              quote.amount_sat + quote.fee_sat == quote.total_sat else { throw JoinBlaketError.invalidResponse }
    }
}

public struct JoinBlaketMarket: Decodable, Sendable {
    public let amount_sat: UInt64, fetched_at: Int64
    public let book_updated_at: Int64?
    public let status: String
    public let maker_count: Int
    public let median_fee_sat: String?
    public func validate(amount: UInt64, now: Int64 = Int64(Date().timeIntervalSince1970)) throws {
        guard amount_sat == amount, ["fresh", "stale", "empty", "unavailable"].contains(status),
              fetched_at <= now + 30, fetched_at >= now - 120, (0...10000).contains(maker_count) else { throw JoinBlaketError.invalidResponse }
        if status == "fresh" {
            guard maker_count > 0, let stamp = book_updated_at, stamp <= now + 30, stamp >= now - 120,
                  let fee = median_fee_sat, fee.range(of: "^[0-9]{1,16}(\\.5)?$", options: .regularExpression) != nil,
                  let value = Decimal(string: fee, locale: Locale(identifier: "en_US_POSIX")), value <= 2_100_000_000_000_000 else { throw JoinBlaketError.invalidResponse }
        } else { guard median_fee_sat == nil, maker_count == 0 else { throw JoinBlaketError.invalidResponse } }
    }
    public func summary(now: Date = Date()) -> String {
        if status == "stale" || (book_updated_at.map { Int64(now.timeIntervalSince1970) - $0 > 120 } ?? false) { return "Order book is stale. Refresh before comparing fees." }
        if status == "empty" { return "No verified bonded offers cover this amount. No median is available." }
        guard status == "fresh", let fee = median_fee_sat else { return "Order book unavailable. Your selected fee is unchanged." }
        return "Median maker fee: \(fee) sats for a \(amount_sat.formatted())-sat CoinJoin · \(maker_count) makers."
    }
}

public enum JoinBlaketMakerFee {
    public static let fixed: [UInt64] = [0, 100, 200, 500, 1000, 2000, 5000, 10000]
    public static let rates = ["0.00002", "0.00005", "0.0001", "0.0002", "0.0005", "0.001", "0.002", "0.005", "0.01", "0.02", "0.05", "0.1"]
    public static let percentages = ["0.002", "0.005", "0.01", "0.02", "0.05", "0.1", "0.2", "0.5", "1", "2", "5", "10"]
    public static let perMillion = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000, 100000]
    public static func label(_ rate: String) -> String { rates.firstIndex(of: rate).map { percentages[$0] + "%" } ?? "Unsupported fee" }
    public static func example(_ rate: String) -> String { rates.firstIndex(of: rate).map { "At 1,000,000 sats, your fee is \(perMillion[$0].formatted()) sats." } ?? "Choose a supported fee." }
}

/// Setup guidance, not a guarantee of market selection or an active bond proof.
public struct JoinBlaketMakerReadiness: Sendable {
    public let terms: Bool
    public let funds: Bool
    public let bond: Bool
    public let server: Bool
    public let fresh: Bool
    public var canStart: Bool { terms && funds && bond && server && fresh }
    public var completedChecks: Int { [terms, funds, bond, server, fresh].filter { $0 }.count }
    public var nextStep: String {
        if !fresh { return "Refresh maker status before continuing." }
        if !terms { return "Review the minimum amount and fee." }
        if !server { return "Wait for Jam to finish its current operation." }
        if !funds { return "Fund a jar and wait for confirmation." }
        if !bond { return "Set up and fund a fidelity bond." }
        return "Ready to review. Your server checks final eligibility."
    }
    public init(minimum: String, fee: String, jars: [JoinBlaketJar], session: JoinBlaketSession?, needsRefresh: Bool, relativeFee: String? = nil) {
        func sats(_ value: String) -> UInt64? {
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return UInt64(value)
        }
        let minimum = sats(minimum) ?? 0, fee = sats(fee)
        let validMinimum = (27_300...2_100_000_000_000_000).contains(minimum)
        terms = validMinimum && (relativeFee.map { JoinBlaketMakerFee.rates.contains($0) && fee == 0 } ?? (fee.map { JoinBlaketMakerFee.fixed.contains($0) && $0 < minimum } ?? false))
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
    private let pairing: JoinBlaketPairing?
    public var canDiscardReviews: Bool { pairing == nil }

    public init(connection: JoinBlaketConnection, pairing: JoinBlaketPairing? = nil) throws {
        try self.init(connection: connection, configuration: .ephemeral, pairing: pairing)
    }
    init(connection: JoinBlaketConnection, configuration: URLSessionConfiguration, pairing: JoinBlaketPairing? = nil) throws {
        try connection.validate()
        if let pairing {
            guard pairing.endpoint == connection.endpoint, pairing.connection.certificateSHA256 == connection.certificateSHA256,
                  pairing.connection.useTor == connection.useTor else { throw ConnectionError.invalidCredential }
        }
        self.pairing = pairing
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

    func request(_ components: [String], authorization: JoinBlaketAuthorization? = nil,
                         body: [String: String]? = nil, jsonBody: Data? = nil) async throws -> Data {
        guard jsonBody == nil || (pairing == nil && body == nil) else { throw JoinBlaketError.invalidResponse }
        var url = try EndpointPolicy.validate(connection.endpoint, tor: connection.useTor, credentials: true)
        let route = pairing == nil ? ["api", "v1"] + components : ["api", "v1", "paired-jars", "request"]
        for component in route {
            // URL path components must not be able to replace the origin or escape the wallet.
            guard !component.isEmpty, !component.contains("/"), !component.contains("\\"),
                  component != ".", component != ".." else { throw JoinBlaketError.invalidResponse }
            url.appendPathComponent(component)
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let pairing {
            guard authorization?.wallet == pairing.wallet, authorization?.token == pairing.token else { throw JoinBlaketError.wrongWallet }
            request.setValue("Bearer " + pairing.token, forHTTPHeaderField: "Authorization")
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: pairing.request(components, body: body))
        } else if let authorization { request.setValue("Bearer " + authorization.token, forHTTPHeaderField: "Authorization") }
        if pairing == nil, let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if let jsonBody {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonBody
        }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw JoinBlaketError.invalidResponse }
            if pairing != nil && !(200..<300).contains(http.statusCode) { throw JoinBlaketError.pairingUnavailable }
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
    /// The companion retains payment recovery across app and daemon restarts.
    /// A missing companion is an error, never an empty history or a legacy send.
    public func payments(_ authorization: JoinBlaketAuthorization) async throws -> [JoinBlaketPayment] {
        _ = try await status(authorization)
        struct Response: Decodable { let payments: [JoinBlaketPayment] }
        let rows = try JSONDecoder().decode(Response.self, from: await request(["wallet", authorization.wallet, "paperclip", "payments"], authorization: authorization)).payments
        guard rows.count <= 100, Set(rows.map(\.id)).count == rows.count else { throw JoinBlaketError.invalidResponse }
        for row in rows { try row.validate(wallet: authorization.wallet) }
        return rows
    }
    public func checkPayment(id: String, authorization: JoinBlaketAuthorization) async throws -> JoinBlaketPayment {
        guard JoinBlaketPayment.validID(id) else { throw JoinBlaketError.invalidResponse }
        _ = try await status(authorization)
        let row = try JSONDecoder().decode(JoinBlaketPayment.self, from: await request(["wallet", authorization.wallet, "paperclip", "payments", id], authorization: authorization))
        guard row.id == id else { throw JoinBlaketError.invalidResponse }
        try row.validate(wallet: authorization.wallet)
        return row
    }
    public func market(amount: UInt64, authorization: JoinBlaketAuthorization) async throws -> JoinBlaketMarket {
        guard (27_300...2_100_000_000_000_000).contains(amount) else { throw JoinBlaketError.invalidResponse }
        _ = try await status(authorization)
        let value = try JSONDecoder().decode(JoinBlaketMarket.self, from: await request(["paperclip", "market", String(amount)], authorization: authorization))
        try value.validate(amount: amount)
        return value
    }
    /// Only an unsent review can be discarded. Existing management-only host
    /// grants retain their scope; use the owner UI for those paired wallets.
    public func discardPayment(id: String, authorization: JoinBlaketAuthorization) async throws -> JoinBlaketPayment {
        guard canDiscardReviews else { throw JoinBlaketError.invalidResponse }
        let saved = try await checkPayment(id: id, authorization: authorization)
        if saved.state == .cancelled { return saved }
        guard saved.canDiscard else { throw JoinBlaketError.invalidResponse }
        let row = try JSONDecoder().decode(JoinBlaketPayment.self, from: await request(["wallet", authorization.wallet, "paperclip", "payments", id, "cancel"], authorization: authorization, body: [:]))
        try row.validate(wallet: authorization.wallet)
        guard row.id == id, row.state == .cancelled else { throw JoinBlaketError.invalidResponse }
        return row
    }
    /// Starts a remote service only after the user reviews its explicit terms.
    /// A timeout means reconcile status; it never causes a second start request.
    public func startMaker(minimumSat: UInt64, feeSat: UInt64, authorization: JoinBlaketAuthorization, relativeFee: String? = nil) async throws {
        guard relativeFee.map({ JoinBlaketMakerFee.rates.contains($0) && feeSat == 0 }) ?? JoinBlaketMakerFee.fixed.contains(feeSat) else { throw JoinBlaketError.invalidResponse }
        guard minimumSat >= 27_300, minimumSat <= 2_100_000_000_000_000, feeSat < minimumSat else { throw JoinBlaketError.invalidResponse }
        let current = try await status(authorization)
        guard !current.maker_running, !current.coinjoin_in_process, !current.rescanning else { throw JoinBlaketError.invalidResponse }
        _ = try await request(["wallet", authorization.wallet, "maker", "start"], authorization: authorization,
                              body: ["txfee": "0", "cjfee_a": String(feeSat), "cjfee_r": relativeFee ?? "0", "ordertype": relativeFee == nil ? "sw0absoffer" : "sw0reloffer", "minsize": String(minimumSat)])
    }
    public func stopMaker(authorization: JoinBlaketAuthorization) async throws {
        _ = try await request(["wallet", authorization.wallet, "maker", "stop"], authorization: authorization)
    }
}
