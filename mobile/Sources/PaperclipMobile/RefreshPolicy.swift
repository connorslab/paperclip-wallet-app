import Foundation

public struct VTXO: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let expiryHeight: Int
    public let spendable: Bool
    public init(id: String, expiryHeight: Int, spendable: Bool) {
        self.id = id; self.expiryHeight = expiryHeight; self.spendable = spendable
    }
}

public struct WalletSnapshot: Codable, Sendable, Equatable {
    public let tip: Int
    public let observedAt: Date
    public let estimatedBlockSeconds: Double
    public let vtxos: [VTXO]
    public init(tip: Int, observedAt: Date, estimatedBlockSeconds: Double, vtxos: [VTXO]) {
        self.tip = tip; self.observedAt = observedAt
        self.estimatedBlockSeconds = estimatedBlockSeconds; self.vtxos = vtxos
    }
}

public struct ExpiryReminder: Equatable, Sendable {
    public let id: String
    public let date: Date
    public let body: String
}

public enum RefreshPolicy {
    public static let refreshWindow = 144
    public static let staleAfter: TimeInterval = 6 * 3600

    public static func eligible(_ snapshot: WalletSnapshot, now: Date) -> [VTXO] {
        guard snapshot.tip >= 0, now >= snapshot.observedAt,
              now.timeIntervalSince(snapshot.observedAt) <= staleAfter else { return [] }
        return snapshot.vtxos.filter {
            $0.spendable && $0.expiryHeight > snapshot.tip &&
            $0.expiryHeight - snapshot.tip <= refreshWindow
        }
    }

    // Calendar estimates are reminders, never proof that funds remain safe.
    // Coalesce by wallet urgency instead of producing a notification per VTXO.
    public static func reminders(_ snapshot: WalletSnapshot, now: Date) -> [ExpiryReminder] {
        guard snapshot.tip >= 0, snapshot.estimatedBlockSeconds.isFinite,
              (1...3600).contains(snapshot.estimatedBlockSeconds),
              let expiry = snapshot.vtxos.map(\.expiryHeight).min() else { return [] }
        if expiry <= snapshot.tip {
            return [ExpiryReminder(id: "paperclip.expiry.recovery", date: now.addingTimeInterval(5),
                body: "An Ark expiry height has been reached. Open Paperclip to check recovery options.")]
        }
        if now < snapshot.observedAt || now.timeIntervalSince(snapshot.observedAt) > staleAfter {
            return [ExpiryReminder(id: "paperclip.expiry.stale", date: now.addingTimeInterval(5),
                body: "Ark expiry information is out of date. Open Paperclip to check and refresh eligible funds.")]
        }
        let estimatedExpiry = snapshot.observedAt.addingTimeInterval(Double(expiry - snapshot.tip) * snapshot.estimatedBlockSeconds)
        var reminders: [ExpiryReminder] = []
        for blocks in [432, 144, 72] {
            let date = estimatedExpiry.addingTimeInterval(-Double(blocks) * snapshot.estimatedBlockSeconds)
            if date <= now {
                if !reminders.contains(where: { $0.id == "paperclip.expiry.now" }) {
                    reminders.append(ExpiryReminder(id: "paperclip.expiry.now", date: now.addingTimeInterval(5),
                        body: "Ark funds may need attention. Open Paperclip to check expiry and refresh eligible funds. Timing is estimated."))
                }
            } else {
                reminders.append(ExpiryReminder(id: "paperclip.expiry.\(blocks)", date: date,
                    body: "Check your Ark funds. Open Paperclip to refresh eligible funds before expiry. Timing is estimated."))
            }
        }
        // This reminder survives a missed background run or an offline device.
        reminders.append(ExpiryReminder(id: "paperclip.expiry.check", date: now.addingTimeInterval(staleAfter),
            body: "Open Paperclip to update your Ark expiry check. Background refresh is not guaranteed."))
        return reminders
    }
}

public protocol WalletEngine: Sendable {
    func synchronize() async throws -> WalletSnapshot
    // Implementations must reconcile persisted round checkpoints before submitting;
    // cancellation must not discard an already-submitted refresh.
    func refreshEligible() async throws
}

public actor RefreshCoordinator {
    private let engine: any WalletEngine
    private var running = false
    public init(engine: any WalletEngine) { self.engine = engine }
    public func run(automatic: Bool, now: Date = Date()) async throws -> WalletSnapshot? {
        guard !running else { return nil }
        running = true
        defer { running = false }
        try Task.checkCancellation()
        let before = try await engine.synchronize()
        if automatic && !RefreshPolicy.eligible(before, now: now).isEmpty {
            try Task.checkCancellation()
            try await engine.refreshEligible()
            try Task.checkCancellation()
            return try await engine.synchronize() // Never report submission as completed renewal.
        }
        return before
    }
}
