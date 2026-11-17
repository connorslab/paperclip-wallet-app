#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import PaperclipMobile

/// Synthetic presentation fixtures; never opens a wallet or sends a payment.
struct Build61Preview: View {
    @StateObject private var store = WalletStore()
    var body: some View {
        Group {
            if ProcessInfo.processInfo.arguments.contains("-wallet-shell-preview") {
                WalletView()
            } else {
            NavigationStack {
            if ProcessInfo.processInfo.arguments.contains("-wallet-health-preview") {
                WalletHealthView()
            } else if ProcessInfo.processInfo.arguments.contains("-recovered-send-preview") {
                SendView.recoveredPaymentPreview()
            } else if ProcessInfo.processInfo.arguments.contains("-backup-center-preview") {
                BackupView(engine: nil)
            } else if ProcessInfo.processInfo.arguments.contains("-payment-assistance-preview") {
                OnchainTransactionView(transaction: ActivityItem(id: String(repeating: "ab", count: 32), title: "Sent", status: "Pending", amountSat: -101000, detail: "Synthetic fixture", date: Date()))
            } else if ProcessInfo.processInfo.arguments.contains("-ark-activity-preview") {
                ArkActivityDetailView(item: ActivityItem(id: "ark-synthetic", title: "Send", status: "Pending", amountSat: -12000, detail: "Synthetic activity · no live funds", date: Date()))
            } else if ProcessInfo.processInfo.arguments.contains("-own-transfer-preview") {
                SendView()
            } else if ProcessInfo.processInfo.arguments.contains("-joinblaket-preview") || ProcessInfo.processInfo.arguments.contains("-joinblaket-setup-preview") {
                JoinBlaketView()
            } else if ProcessInfo.processInfo.arguments.contains("-node-review-preview") {
                LightningView.reviewPreview()
            } else if ProcessInfo.processInfo.arguments.contains("-node-connection-preview") {
                LightningView.connectionPreview()
            } else if ProcessInfo.processInfo.arguments.contains("-lightning-balance-preview") {
                LightningView.balancePreview()
            } else if ProcessInfo.processInfo.arguments.contains("-ark-amount-issue-preview") {
                SendView.arkAmountIssuePreview()
            } else if ProcessInfo.processInfo.arguments.contains("-ark-fee-preview") {
                SendView.arkFeePreview(sendMax: ProcessInfo.processInfo.arguments.contains("-send-max-preview"))
            } else if ProcessInfo.processInfo.arguments.contains("-receive-code-preview") {
                ScrollView {
                    WalletSection("Ready to receive") {
                        ReceiveCode(value: "paperclip-ui-preview-not-a-payment-request")
                        Text("Synthetic preview · no live funds").font(.caption).foregroundStyle(PaperclipTheme.muted)
                    }.walletPageContent()
                }.walletPageBackground().navigationTitle("Receive").navigationBarTitleDisplayMode(.inline)
            } else if ProcessInfo.processInfo.arguments.contains("-receipt-preview") {
                PaymentReceiptView(receipt: PaymentReceipt(state: ProcessInfo.processInfo.arguments.contains("-completed-receipt-preview") ? "completed" : "pending", transactionID: String(repeating: "a1", count: 32), boarding: !ProcessInfo.processInfo.arguments.contains("-completed-receipt-preview")), amount: 48000, mainnet: false) {}
            } else if ProcessInfo.processInfo.arguments.contains("-boarding-preview") {
                ArkToolsView(page: .boarding)
            } else if ProcessInfo.processInfo.arguments.contains("-dashboard-preview") {
                DashboardView()
            } else if ProcessInfo.processInfo.arguments.contains("-notifications-preview") {
                PaymentNotificationSettingsView()
            } else { List {
                NavigationLink("Boarding receipt") {
                    PaymentReceiptView(receipt: PaymentReceipt(state: "pending", transactionID: String(repeating: "a1", count: 32), boarding: true), amount: 48000, mainnet: false) {}
                }
                NavigationLink("Submitted payment") {
                    PaymentReceiptView(receipt: PaymentReceipt(state: "submitted", transactionID: String(repeating: "b2", count: 32)), amount: 5500, mainnet: false) {}
                }
                NavigationLink("Boarding form") { ArkToolsView(page: .boarding) }
                NavigationLink("Notifications") { PaymentNotificationSettingsView() }
            }.navigationTitle("Build 61 previews") }
            }
            }
        }.environmentObject(store).environmentObject(Maintenance.shared).onAppear {
            store.loaded = true; store.hasWallet = true
            store.selectedProfile = WalletProfile(id: "preview", name: "Everyday wallet", kind: .hot, network: "xbt-mainnet")
            if let profile = store.selectedProfile { store.profiles = [profile] }
            if ProcessInfo.processInfo.arguments.contains("-own-transfer-preview") {
                store.profiles.append(WalletProfile(id: "preview-cold", name: "My Krux savings", kind: .hardware, network: "xbt-mainnet"))
            }
            store.onchain = 100000; store.onchainConfirmed = 0; store.onchainPending = 100000; store.ark = 100000
            store.observed = Date()
            if ProcessInfo.processInfo.arguments.contains("-dashboard-preview") || ProcessInfo.processInfo.arguments.contains("-wallet-shell-preview") {
                store.activity = [
                    ActivityItem(id: "preview-chain", title: "Received", status: "Confirmed", amountSat: 100000, detail: "Synthetic preview", date: Date()),
                    ActivityItem(id: "ark-preview", title: "Send", status: "Pending", amountSat: -12000, detail: "Synthetic preview", date: Date().addingTimeInterval(-3600))
                ]
            }
        }
    }
}
#endif
