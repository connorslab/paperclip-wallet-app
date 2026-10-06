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
        // Preserve the on-chain result even when the Ark server is offline.
        let chain = try await engine.operation("sync_onchain")
        onchain = (chain["onchain_sat"] as? NSNumber)?.uint64Value
        do {
            let result = try await engine.balances()
            ark = (result["ark_sat"] as? NSNumber)?.uint64Value
            pending = (result["pending_sat"] as? NSNumber)?.uint64Value
            observed = Date()
            message = "Wallet synchronized."
        } catch { message = "On-chain synchronized. Ark: \(error.localizedDescription)" }
        try await refreshActivity()
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
