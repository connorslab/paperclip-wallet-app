import Foundation

/// Fixed-amount sends with an immutable CoinJoin choice. A fresh reference is created only for a new user draft.
public struct JoinBlaketSendDraft: Sendable {
    public let id: String, jar: UInt8, destination: String
    public let coinjoin: Bool
    public let bondLocktime: Int64?
    public var purpose: String { bondLocktime == nil ? "send" : "fund_bond" }
    public let amountSat: UInt64, feeRateMillisatVb: UInt64, maxFeeSat: UInt64
    public init(jar: UInt8, destination: String, amountSat: UInt64, feeRateMillisatVb: UInt64, maxFeeSat: UInt64, coinjoin: Bool = false, bondLocktime: Int64? = nil,
                id: String = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()) throws {
        self.bondLocktime = bondLocktime; self.coinjoin = coinjoin; self.id = id; self.jar = jar; self.destination = destination
        self.amountSat = amountSat; self.feeRateMillisatVb = feeRateMillisatVb; self.maxFeeSat = maxFeeSat
        try validate()
    }
    func validate() throws {
        if let stamp = bondLocktime {
            guard !coinjoin, stamp > Int64(Date().timeIntervalSince1970), stamp <= 4_099_766_400 else { throw JoinBlaketError.invalidResponse }
        }
        guard JoinBlaketPayment.validID(id), jar < 5, (14...90).contains(destination.utf8.count),
              destination.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
              amountSat > 0, maxFeeSat > 0, amountSat <= 2_100_000_000_000_000,
              maxFeeSat <= 2_100_000_000_000_000 - amountSat,
              (1000...10_000_000).contains(feeRateMillisatVb) else { throw JoinBlaketError.invalidResponse }
    }
    func body() throws -> Data {
        try validate()
        var fields: [String: Any] = ["id": id, "purpose": purpose, "jar": jar,
            "destination": destination, "amount_sat": amountSat, "send_max": false,
            "fee_rate_millisat_vb": feeRateMillisatVb, "max_fee_sat": maxFeeSat,
            "max_total_sat": amountSat + maxFeeSat, "rbf": !coinjoin, "coinjoin": coinjoin]
        if let bondLocktime { fields["bond_locktime"] = bondLocktime }
        return try JSONSerialization.data(withJSONObject: fields)
    }
}

/// Map only the exact fixed-send contract into the host proxy, never a generic Jam route.
func pairedSendFields(_ data: Data, wallet: String) throws -> [String: Any] {
    struct Body: Decodable {
        let id: String, purpose: String, jar: UInt8, destination: String
        let amount_sat: UInt64, fee_rate_millisat_vb: UInt64, max_fee_sat: UInt64, max_total_sat: UInt64
        let send_max: Bool, rbf: Bool, coinjoin: Bool
        let bond_locktime: Int64?
    }
    let body = try JSONDecoder().decode(Body.self, from: data)
    let value = try JoinBlaketSendDraft(jar: body.jar, destination: body.destination, amountSat: body.amount_sat,
        feeRateMillisatVb: body.fee_rate_millisat_vb, maxFeeSat: body.max_fee_sat, coinjoin: body.coinjoin, bondLocktime: body.bond_locktime, id: body.id)
    guard body.purpose == value.purpose, !body.send_max, body.rbf != body.coinjoin,
          body.max_total_sat == value.amountSat + value.maxFeeSat,
          let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any], fields.count == (body.bond_locktime == nil ? 11 : 12) else { throw JoinBlaketError.invalidResponse }
    var terms: [String: Any] = ["jar": value.jar, "destination": value.destination, "amount_sat": value.amountSat,
                     "fee_rate_millisat_vb": value.feeRateMillisatVb, "max_fee_sat": value.maxFeeSat, "coinjoin": value.coinjoin]
    if let stamp = value.bondLocktime { terms["bond_locktime"] = stamp }
    return ["wallet": wallet, "operation": "prepare_payment", "payment_id": value.id, "send": terms]
}

public struct JoinBlaketSendReview: Sendable {
    public let payment: JoinBlaketPayment
    public let approval: String, walletIdentity: String, network: String
    public let expires: Int64
    init(data: Data) throws {
        struct Extra: Decodable {
            struct Quote: Decodable { let wallet_identity: String, network: String; let rbf: Bool }
            let approval: String; let expires: Int64; let quote: Quote
        }
        payment = try JSONDecoder().decode(JoinBlaketPayment.self, from: data)
        let extra = try JSONDecoder().decode(Extra.self, from: data)
        guard extra.quote.rbf == (payment.quote?.coinjoin != true) else { throw JoinBlaketError.invalidResponse }
        approval = extra.approval; expires = extra.expires
        walletIdentity = extra.quote.wallet_identity; network = extra.quote.network
    }
    func validate(draft: JoinBlaketSendDraft, wallet: String, identity: String, now: Int64 = Int64(Date().timeIntervalSince1970)) throws {
        try draft.validate(); try payment.validate(wallet: wallet)
        guard payment.id == draft.id, payment.state == .prepared, JoinBlaketPayment.validID(approval),
              expires > now, expires <= now + 300, walletIdentity == identity,
              ["xbt-mainnet", "xbt-testnet", "xbt-signet", "xbt-regtest"].contains(network),
              identity.hasPrefix(network + ":"), JoinBlaketPayment.validID(String(identity.dropFirst(network.count + 1))),
              let q = payment.quote, q.purpose == draft.purpose, q.bond_locktime == draft.bondLocktime, q.jar == draft.jar,
              q.destination == draft.destination, (q.coinjoin ?? false) == draft.coinjoin, q.amount_sat == draft.amountSat,
              q.fee_sat <= draft.maxFeeSat else { throw JoinBlaketError.invalidResponse }
    }
}

extension JoinBlaketClient {
    private func sendIdentity(_ authorization: JoinBlaketAuthorization) async throws -> String {
        struct Identity: Decodable { let wallet: String, identity: String }
        let value = try JSONDecoder().decode(Identity.self, from: await request(["wallet", authorization.wallet, "paperclip", "identity"], authorization: authorization))
        guard value.wallet == authorization.wallet else { throw JoinBlaketError.wrongWallet }
        let parts = value.identity.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, ["xbt-mainnet", "xbt-testnet", "xbt-signet", "xbt-regtest"].contains(String(parts[0])),
              JoinBlaketPayment.validID(String(parts[1])) else { throw JoinBlaketError.invalidResponse }
        return value.identity
    }
    public func prepareSend(_ draft: JoinBlaketSendDraft, authorization: JoinBlaketAuthorization) async throws -> JoinBlaketSendReview {
        guard canDiscardReviews else { throw JoinBlaketError.invalidResponse }
        try draft.validate()
        let identity = try await sendIdentity(authorization)
        struct Features: Decodable { let version: Int; let reviewed_direct_send: Bool; let coinjoin_payments: Bool?; let bond_funding: Bool? }
        let features = try JSONDecoder().decode(Features.self, from: await request(["paperclip", "capabilities"], authorization: authorization))
        guard [1, 2].contains(features.version), features.reviewed_direct_send else { throw JoinBlaketError.invalidResponse }
        guard draft.bondLocktime == nil || features.bond_funding == true else { throw JoinBlaketError.invalidResponse }
        if draft.coinjoin && !(features.version == 2 && features.coinjoin_payments == true) {
            throw JoinBlaketError.coinJoinUnavailable
        }
        let review = try JoinBlaketSendReview(data: await request(["wallet", authorization.wallet, "paperclip", "payments"], authorization: authorization, jsonBody: draft.body(), preparingCoinJoin: draft.coinjoin))
        try review.validate(draft: draft, wallet: authorization.wallet, identity: identity)
        return review
    }
    /// An interrupted commit is never replayed. Saved recovery remains on the server.
    public func commitSend(_ review: JoinBlaketSendReview, draft: JoinBlaketSendDraft, authorization: JoinBlaketAuthorization) async throws -> JoinBlaketPayment {
        guard canDiscardReviews else { throw JoinBlaketError.invalidResponse }
        try review.validate(draft: draft, wallet: authorization.wallet, identity: review.walletIdentity)
        let identity = try await sendIdentity(authorization)
        guard identity == review.walletIdentity else { throw JoinBlaketError.wrongWallet }
        let path = ["wallet", authorization.wallet, "paperclip", "payments", draft.id]
        let saved = try await request(path + (isPaired ? ["review"] : []), authorization: authorization)
        let current = try JSONDecoder().decode(JoinBlaketPayment.self, from: saved)
        try current.validate(wallet: authorization.wallet)
        guard current.id == draft.id, current.quote == review.payment.quote else { throw JoinBlaketError.invalidResponse }
        if current.needsCheck || current.state == .submitted { return current }
        let checked = try JoinBlaketSendReview(data: saved)
        try checked.validate(draft: draft, wallet: authorization.wallet, identity: identity)
        guard checked.approval == review.approval else { throw JoinBlaketError.invalidResponse }
        let result = try JSONDecoder().decode(JoinBlaketPayment.self, from: await request(path + ["commit"], authorization: authorization, body: ["approval": review.approval], walletIdentity: review.walletIdentity))
        try result.validate(wallet: authorization.wallet)
        guard result.id == draft.id, result.quote == review.payment.quote,
              result.needsCheck || result.state == .submitted else { throw JoinBlaketError.invalidResponse }
        return result
    }
}
