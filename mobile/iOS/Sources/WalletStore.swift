import SwiftUI
import PaperclipMobile
import LocalAuthentication

@MainActor final class WalletStore: ObservableObject {
    @Published var loaded = false
    @Published var hasWallet = false
    @Published var busy = false
    @Published var message = ""
    @Published var onchain: UInt64?
    @Published var ark: UInt64?
    @Published var pending: UInt64?
    @Published var network = "xbt-mainnet"
    @Published var observed: Date?
    @Published var activity: [ActivityItem] = []
    let engine = NativeWallet.shared
    func load() async {
        do {
            hasWallet = try await engine.hasWallet()
            network = try await engine.walletNetwork()
            if hasWallet { _ = try await engine.open() }
        } catch { message = error.localizedDescription }
        loaded = true
    }
    func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task { defer { busy = false }; do { try await action() } catch { message = error.localizedDescription } }
    }
    func synchronize() async throws {
        // Refresh each balance independently; retain cached values on failure.
        var chainWarning: String?
        do {
            let chain = try await engine.operation("sync_onchain")
            onchain = (chain["onchain_sat"] as? NSNumber)?.uint64Value
        } catch { chainWarning = "On-chain refresh: " + error.localizedDescription }
        do {
            let result = try await engine.balances()
            ark = (result["ark_sat"] as? NSNumber)?.uint64Value
            pending = (result["pending_sat"] as? NSNumber)?.uint64Value
            observed = Date()
            if let warning = result["receive_warning"] as? String {
                message = "Wallet synchronized. Pending Ark receive: " + warning
            } else { message = chainWarning == nil ? "Wallet synchronized." : "Ark synchronized." }
        } catch { message = "Ark refresh: \(error.localizedDescription)" }
        if let chainWarning { message += "\n" + chainWarning }
        try await refreshActivity()
    }
    func refreshCachedArkBalance() async {
        guard !busy else { return }
        guard let result = try? await engine.operation("balance_cached") else { return }
        ark = (result["ark_sat"] as? NSNumber)?.uint64Value
        pending = (result["pending_sat"] as? NSNumber)?.uint64Value
    }
    func refreshActivity() async throws {
        let result = try await engine.activity()
        let movements = result["movements"] as? [[String: Any]] ?? []
        activity = movements.reversed().enumerated().map { index, item in
            ActivityItem(id: "ark-\(item["id"] ?? index)", title: "Ark", status: "\(item["status"] ?? "pending")",
                amount: "\(item["effective_balance"] ?? 0) sats", detail: "\(item["created_at"] ?? "")")
        }
        activity += (result["onchain"] as? [[String: Any]] ?? []).map { item in
            ActivityItem(id: "\(item["txid"] ?? UUID().uuidString)", title: "On-chain",
                status: item["confirmed"] as? Bool == true ? "Confirmed" : "Pending",
                amount: "\(item["change_sat"] ?? 0) sats", detail: "\(item["txid"] ?? "")")
        }
    }
}

struct ActivityItem: Identifiable {
    let id: String
    let title: String
    let status: String
    let amount: String
    let detail: String
}

@MainActor final class WalletLock: ObservableObject {
    @Published var unlocked = false
    @Published var error = ""
    private var authenticating = false
    func unlock() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ui-testing") { unlocked = true; return }
        #endif
        guard !authenticating else { return }
        authenticating = true; defer { authenticating = false }
        let context = LAContext()
        do {
            unlocked = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your Paperclip wallet")
        } catch { self.error = "Unlock with Face ID, Touch ID, or your device passcode." }
    }
}
