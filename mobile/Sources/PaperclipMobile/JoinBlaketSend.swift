import Foundation

/// Fixed-amount direct sends. A fresh reference is created only for a new user draft.
public struct JoinBlaketSendDraft: Sendable {
    public let id: String, jar: UInt8, destination: String
    public let amountSat: UInt64, feeRateMillisatVb: UInt64, maxFeeSat: UInt64
    public init(jar: UInt8, destination: String, amountSat: UInt64, feeRateMillisatVb: UInt64, maxFeeSat: UInt64,
                id: String = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()) throws {
        self.id = id; self.jar = jar; self.destination = destination
        self.amountSat = amountSat; self.feeRateMillisatVb = feeRateMillisatVb; self.maxFeeSat = maxFeeSat
        try validate()
    }
    func validate() throws {
        guard JoinBlaketPayment.validID(id), jar < 5, (14...90).contains(destination.utf8.count),
              destination.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
              amountSat > 0, maxFeeSat > 0, amountSat <= 2_100_000_000_000_000,
              maxFeeSat <= 2_100_000_000_000_000 - amountSat,
              (1000...10_000_000).contains(feeRateMillisatVb) else { throw JoinBlaketError.invalidResponse }
    }
    func body() throws -> Data {
        try validate()
        return try JSONSerialization.data(withJSONObject: ["id": id, "purpose": "send", "jar": jar,
            "destination": destination, "amount_sat": amountSat, "send_max": false,
            "fee_rate_millisat_vb": feeRateMillisatVb, "max_fee_sat": maxFeeSat,
            "max_total_sat": amountSat + maxFeeSat, "rbf": true])
    }
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
        guard extra.quote.rbf else { throw JoinBlaketError.invalidResponse }
        approval = extra.approval; expires = extra.expires
        walletIdentity = extra.quote.wallet_identity; network = extra.quote.network
    }
    func validate(draft: JoinBlaketSendDraft, wallet: String, identity: String, now: Int64 = Int64(Date().timeIntervalSince1970)) throws {
        try draft.validate(); try payment.validate(wallet: wallet)
        guard payment.id == draft.id, payment.state == .prepared, JoinBlaketPayment.validID(approval),
              expires > now, expires <= now + 300, walletIdentity == identity,
              ["xbt-mainnet", "xbt-testnet", "xbt-signet", "xbt-regtest"].contains(network),
              identity.hasPrefix(network + ":"), JoinBlaketPayment.validID(String(identity.dropFirst(network.count + 1))),
              let q = payment.quote, q.purpose == "send", q.jar == draft.jar,
              q.destination == draft.destination, q.amount_sat == draft.amountSat,
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
        struct Features: Decodable { let version: Int; let reviewed_direct_send: Bool }
        let features = try JSONDecoder().decode(Features.self, from: await request(["paperclip", "capabilities"], authorization: authorization))
        guard features.version == 1, features.reviewed_direct_send else { throw JoinBlaketError.invalidResponse }
        let review = try JoinBlaketSendReview(data: await request(["wallet", authorization.wallet, "paperclip", "payments"], authorization: authorization, jsonBody: draft.body()))
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
        let saved = try await request(path, authorization: authorization)
        let current = try JSONDecoder().decode(JoinBlaketPayment.self, from: saved)
        try current.validate(wallet: authorization.wallet)
        guard current.id == draft.id, current.quote == review.payment.quote else { throw JoinBlaketError.invalidResponse }
        if current.needsCheck || current.state == .submitted { return current }
        let checked = try JoinBlaketSendReview(data: saved)
        try checked.validate(draft: draft, wallet: authorization.wallet, identity: identity)
        guard checked.approval == review.approval else { throw JoinBlaketError.invalidResponse }
        let result = try JSONDecoder().decode(JoinBlaketPayment.self, from: await request(path + ["commit"], authorization: authorization, body: ["approval": review.approval]))
        try result.validate(wallet: authorization.wallet)
        guard result.id == draft.id, result.quote == review.payment.quote,
              result.needsCheck || result.state == .submitted else { throw JoinBlaketError.invalidResponse }
        return result
    }
}
