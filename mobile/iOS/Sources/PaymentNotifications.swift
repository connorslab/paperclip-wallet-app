import SwiftUI
import UserNotifications
import PaperclipMobile
import CryptoKit

@MainActor final class PaymentNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PaymentNotifications()
    private let center = UNUserNotificationCenter.current()
    override init() {
        super.init()
        center.delegate = self
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
    private var states: [String: ActivityNotificationState] = [:]
    private func key(_ scope: String) -> String {
        "payment-alerts-" + SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func forgetWallet(_ walletID: String) async {
        let prefixes = ["taproot", "segwit", "public", "ark"].map { key(walletID + ":" + $0) }
        for prefix in prefixes { states.removeValue(forKey: prefix); try? WalletKeychain.delete(prefix) }
        let delivered = await center.deliveredNotifications().map { $0.request.identifier }.filter { id in prefixes.contains { id.hasPrefix($0 + ".") } }
        center.removeDeliveredNotifications(withIdentifiers: delivered)
    }
    func resetBaseline(scope: String) {
        let storageKey = key(scope)
        states[storageKey] = ActivityNotificationState()
        if let data = try? JSONEncoder().encode(ActivityNotificationState()) { try? WalletKeychain.save(data, account: storageKey) }
    }
    func observeWallet(_ items: [ActivityItem], walletID: String, account: String) async {
        await observe(items.filter { $0.id.hasPrefix("ark-") }, scope: walletID + ":ark")
        await observe(items.filter { !$0.id.hasPrefix("ark-") }, scope: walletID + ":" + account)
    }
    func observe(_ items: [ActivityItem], scope: String) async {
        guard UserDefaults.standard.bool(forKey: "paymentNotifications") else { return }
        let storageKey = key(scope)
        if states[storageKey] == nil {
            states[storageKey] = (try? WalletKeychain.read(storageKey)).flatMap { try? JSONDecoder().decode(ActivityNotificationState.self, from: $0) } ?? ActivityNotificationState()
        }
        var state = states[storageKey] ?? ActivityNotificationState()
        let changes = state.changes(items)
        // Save before delivery to prevent duplicate alerts after a restart.
        guard let data = try? JSONEncoder().encode(state), (try? WalletKeychain.save(data, account: storageKey)) != nil else { return }
        states[storageKey] = state
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        for item in changes.prefix(5) {
            let content = UNMutableNotificationContent()
            content.title = item.amountSat > 0 ? "Incoming payment update" : "Outgoing payment update"
            content.body = "Status: \(item.status). Open Paperclip to view the details."
            content.sound = .default
            // No balances, addresses, wallet names, or transaction IDs on the lock screen.
            let identifier = storageKey + "." + key(item.id + item.status)
            try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }
}

struct PaymentNotificationSettingsView: View {
    @AppStorage("paymentNotifications") private var enabled = false
    @EnvironmentObject var store: WalletStore
    @State private var status = ""
    var body: some View {
        ScrollView { VStack(spacing: 20) {
            WalletSection("Payment alerts") {
                Toggle("Send and receive updates", isOn: $enabled)
                Text("Alerts appear when a wallet refresh detects a new payment or a changed status. Amounts and addresses stay hidden in notifications.").font(.subheadline)
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(PaperclipTheme.muted) }
            }
            WalletSection("When to expect an alert") {
                Label("Uses existing refreshes", systemImage: "battery.100")
                Text("Paperclip does not keep a connection running in the background for alerts. iOS decides when background refresh can run; alerts can be delayed or absent until you open the app.")
                Text("Only the selected wallet is checked. Open each wallet to refresh its activity. Background Ark checks require access to protected wallet data and may wait until you unlock your iPhone.")
                Text("These alerts cover on-chain and Ark activity, not payments on connected Lightning nodes. Hardware and watch-only wallets refresh while open. Keep opening the app regularly to check pending payments and Ark expiry.")
            }.font(.subheadline)
            Button("Open notification settings") { if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) } }
        }.walletPageContent() }.walletPageBackground().navigationTitle("Notifications")
            .onChange(of: enabled) { _, value in
                guard value else { return }
                Task {
                    let allowed = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) == true
                    status = allowed ? "Payment alerts enabled." : "Allow notifications in iOS Settings to receive alerts."
                    PaymentNotifications.shared.resetBaseline(scope: store.walletID + ":ark")
                    PaymentNotifications.shared.resetBaseline(scope: store.walletID + ":" + store.onchainAccount)
                    try? await store.refreshActivity()
                }
            }
    }
}
