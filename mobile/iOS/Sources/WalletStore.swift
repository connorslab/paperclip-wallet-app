import SwiftUI
import PaperclipMobile
import LocalAuthentication

@MainActor final class WalletStore: ObservableObject {
    @Published var profiles: [WalletProfile] = []
    @Published var selectedProfile: WalletProfile?
    var supportsArk: Bool { selectedProfile?.supportsArk ?? true }
    var isHardware: Bool { selectedProfile?.kind == .hardware }
    var isWatchOnly: Bool { selectedProfile?.kind == .watch }
    var walletID: String { selectedProfile?.id ?? "setup" }
    @Published var loaded = false
    @Published var hasWallet = false
    @Published var busy = false
    @Published private(set) var syncing = false
    private var actionTask: Task<Void, Never>?
    private var lastSuccessfulRefresh: (wallet: String, account: String, date: Date)?
    func refreshOnAppearance() {
        if let last = lastSuccessfulRefresh, last.wallet == walletID, last.account == onchainAccount,
           Date().timeIntervalSince(last.date) < 60 { return }
        runSync { try await self.synchronize() }
    }
    func pauseSync() async {
        guard syncing, let task = actionTask else { return }
        task.cancel()
        await task.value
    }
    @Published var message = ""
    @Published var onchainAccount = "taproot"
    @Published var onchain: UInt64?
    @Published var onchainConfirmed: UInt64?
    @Published var onchainPending: UInt64?
    @Published var onchainImmature: UInt64?
    func applyOnchainOverview(_ overview: [String: Any]) {
        onchain = (overview["total_sat"] as? NSNumber)?.uint64Value
        onchainConfirmed = (overview["confirmed_sat"] as? NSNumber)?.uint64Value
        onchainPending = (overview["unconfirmed_sat"] as? NSNumber)?.uint64Value
        onchainImmature = (overview["immature_sat"] as? NSNumber)?.uint64Value
    }
    @Published var ark: UInt64?
    @Published var pending: UInt64?
    @Published var network = "xbt-mainnet"
    @Published var observed: Date?
    @Published var chainChecked: Date?
    @Published var chainReachable = false
    @Published var chainChecking = false
    private var lastChainAttempt: Date?
    var chainConnected: Bool { chainReachable && chainChecked.map { Date().timeIntervalSince($0) < 75 } == true }
    var chainConnectionDescription: String {
        if chainConnected { return "On-chain backend connected" }
        return chainChecking ? "Checking on-chain connection" : "On-chain connection not verified"
    }
    func checkChainConnection(force: Bool = false) async {
        guard !chainChecking, hasWallet else { return }
        if !force, let lastChainAttempt, Date().timeIntervalSince(lastChainAttempt) < 30 { return }
        let identity = walletID
        lastChainAttempt = Date(); chainChecking = true
        defer { chainChecking = false }
        do {
            let result = try await engine.operation("chain_health")
            guard identity == walletID else { return }
            chainReachable = result["connected"] as? Bool == true
            chainChecked = Date()
        } catch { if identity == walletID { chainReachable = false; chainChecked = nil } }
    }
    @Published var activity: [ActivityItem] = []
    let engine = NativeWallet.shared
    func load() async {
        do {
            let profile = try await engine.selectedProfile()
            if selectedProfile?.id != profile?.id {
                onchain = nil; onchainConfirmed = nil; onchainPending = nil; onchainImmature = nil; ark = nil; pending = nil; activity = []; observed = nil
                chainChecked = nil; chainReachable = false; lastChainAttempt = nil; message = ""
            }
            profiles = try await engine.profiles(); selectedProfile = profile
            hasWallet = try await engine.hasWallet()
            network = try await engine.walletNetwork()
            if hasWallet {
                _ = try await engine.open()
                let overview = try await engine.onchainOverview()
                onchainAccount = overview["account"] as? String ?? "taproot"
                applyOnchainOverview(overview)
            }
        } catch { message = error.localizedDescription }
        loaded = true
    }
    func selectWallet(_ profile: WalletProfile) async throws {
        guard !Maintenance.shared.busy else { throw WalletFailure(message: "Ark maintenance is finishing. Try switching again in a moment.") }
        try await engine.activate(profile.id)
        await load()
    }
    func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        // A user operation may change funds; do not debounce the next refresh.
        lastSuccessfulRefresh = nil
        busy = true
        actionTask = Task { defer { busy = false }; do { try await action() } catch is CancellationError { message = "Refresh paused. You can resume it from the wallet." } catch { message = error.localizedDescription } }
    }
    func runSync(_ action: @escaping @MainActor () async throws -> Void) {
        run {
            self.syncing = true; defer { self.syncing = false }
            try await action()
        }
    }
    func synchronize() async throws {
        syncing = true; defer { syncing = false }
        message = "Refreshing balances… Cached amounts remain visible."
        // Refresh each balance independently; retain cached values on failure.
        var chainWarning: String?
        do {
            let chain = try await engine.operation("sync_onchain")
            onchain = (chain["onchain_sat"] as? NSNumber)?.uint64Value
            applyOnchainOverview(try await engine.onchainOverview())
            chainReachable = true; chainChecked = Date(); lastChainAttempt = Date()
        } catch { chainReachable = false; chainChecked = nil; chainWarning = "On-chain refresh: " + error.localizedDescription }
        try Task.checkCancellation()
        if !supportsArk {
            ark = nil; pending = nil; observed = Date()
            message = chainWarning ?? "On-chain wallet synchronized."
            try await refreshActivity()
            if chainWarning == nil { lastSuccessfulRefresh = (walletID, onchainAccount, Date()) }
            return
        }
        do {
            let result = try await engine.balances()
            ark = (result["ark_sat"] as? NSNumber)?.uint64Value
            pending = (result["pending_sat"] as? NSNumber)?.uint64Value
            observed = Date()
            if let warning = result["receive_warning"] as? String {
                message = "Wallet synchronized. Pending Ark receive: " + warning
            } else { message = chainWarning == nil ? "Wallet synchronized." : "Ark synchronized." }
            if let warning = result["recovery_warning"] as? String {
                message += "\nArk recovery registration will retry: " + warning
            }
        } catch { message = "Ark refresh: \(error.localizedDescription)" }
        if let chainWarning { message += "\n" + chainWarning }
        try Task.checkCancellation()
        try await refreshActivity()
        if chainWarning == nil { lastSuccessfulRefresh = (walletID, onchainAccount, Date()) }
    }
    func refreshCachedArkBalance() async {
        guard !busy else { return }
        let identity = walletID
        await checkChainConnection()
        guard !busy, identity == walletID, supportsArk else { return }
        guard let result = try? await engine.operation("balance_cached") else { return }
        guard identity == walletID else { return }
        ark = (result["ark_sat"] as? NSNumber)?.uint64Value
        pending = (result["pending_sat"] as? NSNumber)?.uint64Value
    }
    func refreshActivity() async throws {
        let identity = walletID, account = onchainAccount
        let result = try await engine.activity()
        guard identity == walletID, account == onchainAccount else { return }
        activity = Self.activityItems(result)
        await PaymentNotifications.shared.observeWallet(activity, walletID: identity, account: account)
    }
    static func activityItems(_ result: [String: Any]) -> [ActivityItem] {
        let movements = result["movements"] as? [[String: Any]] ?? []
        var activity = movements.reversed().enumerated().map { index, item in
            let subsystem = item["subsystem"] as? [String: Any] ?? [:]
            let kind = (subsystem["kind"] as? String ?? "Ark payment").replacingOccurrences(of: "_", with: " ").capitalized
            let time = item["time"] as? [String: Any] ?? [:]
            return ActivityItem(id: "ark-\(item["id"] ?? index)", title: kind, status: "\(item["status"] ?? "pending")".replacingOccurrences(of: "_", with: " ").capitalized,
                amountSat: (item["effective_balance"] as? NSNumber)?.int64Value ?? 0, detail: "\(time["created_at"] ?? "")", date: ActivityItem.parseDate(time["created_at"] as? String))
        }
        activity += (result["onchain"] as? [[String: Any]] ?? []).map { item in
            ActivityItem(id: "\(item["txid"] ?? UUID().uuidString)", title: "On-chain",
                status: item["confirmed"] as? Bool == true ? "Confirmed" : "Pending",
                amountSat: (item["change_sat"] as? NSNumber)?.int64Value ?? 0, detail: "\(item["txid"] ?? "")", date: ActivityItem.unixDate((item["timestamp"] as? NSNumber)?.doubleValue))
        }
        return ActivityItem.newestFirst(activity)
    }
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
