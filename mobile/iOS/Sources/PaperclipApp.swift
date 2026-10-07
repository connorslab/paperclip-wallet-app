import SwiftUI
import PaperclipMobile

@main struct PaperclipApp: App {
    @Environment(\.scenePhase) private var scene
    @StateObject private var maintenance = Maintenance.shared
    @StateObject private var store = WalletStore()
    @StateObject private var lock = WalletLock()
    @StateObject private var nodePayments = LightningPaymentMonitor.shared
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("walletLock") private var lockEnabled = true
    init() {
        UserDefaults.standard.register(defaults: ["automaticRefresh": true, "walletLock": true])
        Maintenance.shared.register()
    }
    var body: some Scene {
        WindowGroup {
            ZStack {
                WalletView().environmentObject(store).environmentObject(maintenance)
                if store.hasWallet && lockEnabled && !lock.unlocked {
                    VStack(spacing: 24) {
                        Image(systemName: "lock.shield").font(.system(size: 56)).foregroundStyle(PaperclipTheme.orange)
                        Text("Your XBT. Your keys.").font(.title.bold())
                        Button("Unlock Paperclip") { Task { await lock.unlock() } }.buttonStyle(.borderedProminent)
                        Text(lock.error).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(PaperclipTheme.navy)
                }
                if scene != .active {
                    PaperclipTheme.navy.ignoresSafeArea().overlay(Image("PaperclipLogo").resizable().scaledToFit().frame(width: 72, height: 72))
                }
            }
            .tint(PaperclipTheme.orange).preferredColorScheme(appearance == "system" ? nil : appearance == "light" ? .light : .dark)
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-tor-probe") {
                    await TorProbe.run()
                    return
                }
                #endif
                await store.load()
                nodePayments.setForeground(true)
                if store.hasWallet && lockEnabled { await lock.unlock() }
                if store.hasWallet {
                    await store.engine.setForeground(true)
                    await maintenance.update(automatic: UserDefaults.standard.bool(forKey: "automaticRefresh"))
                }
            }
            .onChange(of: store.hasWallet) { _, present in
                if present && lockEnabled { Task { await lock.unlock() } }
            }
            .onChange(of: scene) { _, phase in
                if phase == .active {
                    nodePayments.setForeground(true)
                    Task {
                        await store.engine.setForeground(true)
                        if store.hasWallet && lockEnabled && !lock.unlocked { await lock.unlock() }
                        if store.hasWallet { await maintenance.update(automatic: UserDefaults.standard.bool(forKey: "automaticRefresh")) }
                    }
                } else if phase == .background { nodePayments.setForeground(false); lock.unlocked = false; maintenance.schedule(); Task { await store.engine.setForeground(false) } }
            }
        }
    }
}

struct WalletView: View {
    @EnvironmentObject var store: WalletStore
    var body: some View {
        Group {
            if !store.loaded { ProgressView("Open secure storage…") }
            else if !store.hasWallet { SetupView() }
            else {
                TabView {
                    NavigationStack { DashboardView() }.tabItem { Label("Wallet", systemImage: "wallet.pass") }
                    if store.supportsArk { NavigationStack { LightningView() }.tabItem { Label("Lightning", systemImage: "bolt.fill") } }
                    NavigationStack { ActivityView() }.tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }
                    NavigationStack { SettingsView() }.tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
                }.id(store.walletID)
            }
        }.background(PaperclipTheme.navy)
    }
}

struct DashboardView: View {
    @AppStorage("displayUnit") private var unit: BitcoinUnit = .sats
    @EnvironmentObject var store: WalletStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sending = false
    @State private var receiving = false
    @State private var hideBalance = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                WalletBrand()
                HStack {
                    Label {
                        Text(store.network == "xbt-mainnet" ? "XBT MAINNET" : "REGTEST")
                    } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(store.chainConnected ? Color.green : PaperclipTheme.muted)
                    }.font(.caption2).tracking(2)
                        .accessibilityLabel("\(store.network == "xbt-mainnet" ? "XBT mainnet" : "Regtest"). \(store.chainConnectionDescription)")
                    Spacer()
                    Button { hideBalance.toggle() } label: { Image(systemName: hideBalance ? "eye.slash" : "eye") }.accessibilityLabel("Toggle balance visibility")
                }.foregroundStyle(PaperclipTheme.muted)
                WalletCard {
                    Text("Your XBT.\nWithin reach.").font(.largeTitle.bold())
                    Text(total).font(.system(size: 42, weight: .semibold, design: .rounded)).minimumScaleFactor(0.5).lineLimit(1).privacySensitive()
                        .contentTransition(.numericText())
                    Text("\(unit.title.uppercased()) · " + (store.supportsArk ? "ON-CHAIN + ARK" : "ON-CHAIN")).font(.caption2).tracking(2).foregroundStyle(PaperclipTheme.muted)
                    HStack(spacing: 12) {
                        if !store.isWatchOnly { Button { sending = true } label: { Label("Send", systemImage: "arrow.up.right").frame(maxWidth: .infinity) }.modifier(GlassAction()) }
                        Button { receiving = true } label: { Label("Receive", systemImage: "arrow.down.left").frame(maxWidth: .infinity) }.modifier(GlassAction())
                    }.font(.headline)
                }
                HStack(spacing: 14) {
                    NavigationLink { OnchainOverviewView() } label: {
                        balanceCard("On-chain", icon: "link", amount: store.onchain)
                    }.buttonStyle(.plain).accessibilityHint("View on-chain balances and transactions")
                    if store.supportsArk { NavigationLink { ArkOverviewView() } label: {
                        balanceCard("Ark", icon: "square.stack.3d.up", amount: store.ark)
                    }.buttonStyle(.plain).accessibilityHint("View Ark balances, payments, and activity") }
                }
                if let pending = store.pending, pending > 0 { Label("\(unit.display(pending)) pending", systemImage: "clock").font(.subheadline) }
                if store.observed == nil {
                    NavigationLink { ConnectionsView() } label: { Label("Configure your connection", systemImage: "network") }
                }
                HStack { if store.busy { ProgressView() }; Text(store.message).font(.caption).foregroundStyle(PaperclipTheme.muted) }
                if store.supportsArk, let date = store.observed { Text("Ark last checked \(date.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.secondary) }
            }.padding(22)
        }.background(PaperclipTheme.navy).navigationBarTitleDisplayMode(.inline)
            .task {
                // A switch/add finishes its UI action after the new dashboard appears.
                while store.busy && !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
                guard !Task.isCancelled else { return }
                store.run { try await store.synchronize() }
                while !Task.isCancelled {
                    await store.refreshCachedArkBalance()
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
            .toolbar { Button { store.run { try await store.synchronize() } } label: { Image(systemName: "arrow.clockwise") }.disabled(store.busy).accessibilityLabel("Synchronize wallet") }
            .refreshable { guard !store.busy else { return }; store.run { try await store.synchronize() } }
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: store.onchain)
            .sheet(isPresented: $sending) { NavigationStack { WalletSendView() } }
            .sheet(isPresented: $receiving) { NavigationStack { ReceiveView() } }
    }
    private var total: String {
        if hideBalance { return "••••••" }
        guard let chain = store.onchain else { return "—" }
        if !store.supportsArk { return unit.number(chain) }
        guard let ark = store.ark else { return "—" }
        return unit.number(chain + ark)
    }
    private func balanceCard(_ title: String, icon: String, amount: UInt64?) -> some View {
        WalletCard {
            Label(title, systemImage: icon).font(.subheadline).foregroundStyle(PaperclipTheme.muted)
            Text(hideBalance ? "••••" : amount.map { unit.number($0) } ?? "—").font(.title2.bold()).lineLimit(1).minimumScaleFactor(0.6).privacySensitive()
            Text(unit.title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ActivityView: View {
    @AppStorage("displayUnit") private var unit: BitcoinUnit = .sats
    @EnvironmentObject var store: WalletStore
    @State private var filter = "All"
    private var items: [ActivityItem] { store.activity.filter {
        filter == "All" || (filter == "Ark" ? $0.id.hasPrefix("ark-") : !$0.id.hasPrefix("ark-"))
    } }
    var body: some View {
        ScrollView {
          VStack(spacing: 20) {
            Picker("Activity wallet", selection: $filter) {
                Text("All").tag("All"); Text("On-chain").tag("On-chain"); Text("Ark").tag("Ark")
            }.pickerStyle(.segmented)
            if items.isEmpty { ContentUnavailableView("No activity loaded", systemImage: "clock", description: Text("Synchronize your wallet to load transactions.")) }
            ForEach(items) { item in
                if !item.id.hasPrefix("ark-") {
                    NavigationLink { OnchainTransactionView(transaction: item) } label: {
                        WalletCard { OnchainTransactionRow(item: item) }
                    }.buttonStyle(.plain)
                } else {
                    WalletCard {
                        HStack { Text(item.title).font(.headline); Spacer(); Text(unit.signed(item.amountSat)).monospacedDigit() }
                        Text(item.status).foregroundStyle(PaperclipTheme.orange)
                        Text(item.detail).font(.caption2.monospaced()).textSelection(.enabled)
                    }
                }
            }
            Text(store.message).font(.caption)
          }.padding(22)
        }.scrollContentBackground(.hidden).background(PaperclipTheme.navy).navigationTitle("Activity")
            .toolbar { Button("Refresh") { store.run { try await store.refreshActivity() } }.disabled(store.busy) }
    }
}

struct OnchainOverviewView: View {
    @AppStorage("displayUnit") private var unit: BitcoinUnit = .sats
    @EnvironmentObject var store: WalletStore
    @State private var confirmed: UInt64?
    @State private var unconfirmed: UInt64?
    @State private var immature: UInt64?
    @State private var transactions: [ActivityItem] = []
    @State private var status = "Saved wallet state. Refresh to check the network."
    @State private var loading = false
    var body: some View {
        ScrollView {
          VStack(spacing: 20) {
            WalletSection("Balance") {
                LabeledContent("Confirmed", value: sats(confirmed))
                LabeledContent("Unconfirmed", value: sats(unconfirmed))
                if let immature, immature > 0 { LabeledContent("Immature mining rewards", value: sats(immature)) }
                Text("Unconfirmed includes pending incoming outputs and change. Amounts reflect the wallet's unspent outputs.").font(.caption)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            WalletSection("On-chain actions") {
                HStack {
                    if !store.isWatchOnly { NavigationLink { WalletSendView() } label: { Label("Send", systemImage: "arrow.up.right").frame(maxWidth: .infinity) }.modifier(GlassAction()) }
                    NavigationLink { ReceiveView() } label: { Label("Receive", systemImage: "arrow.down.left").frame(maxWidth: .infinity) }.modifier(GlassAction())
                }
                NavigationLink { OnchainAddressesView() } label: { WalletNavigationRow("Wallet addresses", subtitle: "View derived receive and change addresses", icon: "list.bullet") }
            }
            WalletSection("On-chain transactions") {
                if transactions.isEmpty { Text("No on-chain transactions in the saved wallet state.").foregroundStyle(.secondary) }
                ForEach(transactions) { item in
                    NavigationLink { OnchainTransactionView(transaction: item) } label: {
                        OnchainTransactionRow(item: item)
                    }.buttonStyle(.plain)
                }
            }
          }.padding(22)
        }.navigationTitle("On-chain")
            .scrollContentBackground(.hidden).background(PaperclipTheme.navy)
            .toolbar {
                Button { Task { await refresh() } } label: {
                    if loading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }.disabled(loading || store.busy).accessibilityLabel("Refresh on-chain wallet")
            }
            .task { await load() }
            .refreshable { await refresh() }
    }
    private func sats(_ amount: UInt64?) -> String { unit.display(amount) }
    private func load() async {
        do {
            let result = try await store.engine.onchainOverview()
            confirmed = (result["confirmed_sat"] as? NSNumber)?.uint64Value
            unconfirmed = (result["unconfirmed_sat"] as? NSNumber)?.uint64Value
            immature = (result["immature_sat"] as? NSNumber)?.uint64Value
            store.onchain = (result["total_sat"] as? NSNumber)?.uint64Value
            transactions = (result["transactions"] as? [[String: Any]] ?? []).compactMap { row in
                guard let txid = row["txid"] as? String, let amount = row["change_sat"] as? NSNumber else { return nil }
                return ActivityItem(id: txid, title: "On-chain", status: row["confirmed"] as? Bool == true ? "Confirmed" : "Unconfirmed",
                    amountSat: amount.int64Value, detail: txid, date: ActivityItem.unixDate((row["timestamp"] as? NSNumber)?.doubleValue))
            }
            transactions = ActivityItem.newestFirst(transactions)
        } catch { status = error.localizedDescription }
    }
    private func refresh() async {
        guard !loading, !store.busy else { return }
        loading = true; store.busy = true
        defer { loading = false; store.busy = false }
        do {
            _ = try await store.engine.operation("sync_onchain")
            status = "Updated \(Date().formatted(date: .omitted, time: .shortened))"
        } catch { status = "Showing saved state. \(error.localizedDescription)" }
        await load()
    }
}

struct ArkOverviewView: View {
    @AppStorage("displayUnit") private var unit: BitcoinUnit = .sats
    @EnvironmentObject var store: WalletStore
    @State private var sending = false
    @State private var receiving = false
    private var transactions: [ActivityItem] { store.activity.filter { $0.id.hasPrefix("ark-") } }
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                WalletSection("Ark balance") {
                    Text(unit.display(store.ark)).font(.largeTitle.bold()).privacySensitive().contentTransition(.numericText())
                    Text("Available to spend").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                    LabeledContent("Pending", value: unit.display(store.pending))
                    HStack {
                        Button { sending = true } label: { Label("Pay", systemImage: "arrow.up.right").frame(maxWidth: .infinity) }.modifier(GlassAction())
                        Button { receiving = true } label: { Label("Receive", systemImage: "arrow.down.left").frame(maxWidth: .infinity) }.modifier(GlassAction())
                    }
                    Text("Pending funds are not yet available. Keep the app open to finish incoming Lightning payments.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                }
                WalletSection("Manage Ark") {
                    NavigationLink { ArkToolsView(page: .boarding) } label: { WalletNavigationRow("Add to Ark", subtitle: "Board funds from your on-chain wallet", icon: "arrow.down.to.line") }
                    NavigationLink { SendView(onchain: false) } label: { WalletNavigationRow("Withdraw to on-chain", subtitle: "Send to an XBT address", icon: "arrow.up.right") }
                    NavigationLink { ArkLightningReceivesView() } label: { WalletNavigationRow("Lightning receives", subtitle: "Check incoming payments and claims", icon: "bolt") }
                    NavigationLink { ArkToolsView() } label: { WalletNavigationRow("Backup & recovery", subtitle: "Protect and recover your Ark funds", icon: "shield") }
                }
                WalletSection("Ark activity") {
                    if transactions.isEmpty { Text("No Ark activity yet. Received and sent payments will appear here.").foregroundStyle(PaperclipTheme.muted) }
                    ForEach(transactions) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text(item.title).font(.headline); Spacer(); Text(unit.signed(item.amountSat)).monospacedDigit() }
                            Text(item.status).foregroundStyle(PaperclipTheme.orange)
                            Text(item.detail).font(.caption).foregroundStyle(PaperclipTheme.muted)
                        }
                        Divider()
                    }
                }
                if !store.message.isEmpty { Text(store.message).font(.caption).foregroundStyle(PaperclipTheme.muted) }
            }.padding(22)
        }.background(PaperclipTheme.navy.ignoresSafeArea()).navigationTitle("Ark")
            .toolbar { Button { refresh() } label: { Image(systemName: "arrow.clockwise") }.disabled(store.busy).accessibilityLabel("Refresh Ark") }
            .task { refresh() }
            .refreshable { refresh() }
            .sheet(isPresented: $sending) { NavigationStack { SendView(onchain: false) } }
            .sheet(isPresented: $receiving) { NavigationStack { ReceiveView(route: 1) } }
    }
    private func refresh() {
        store.run {
            let result = try await store.engine.balances()
            store.ark = (result["ark_sat"] as? NSNumber)?.uint64Value
            store.pending = (result["pending_sat"] as? NSNumber)?.uint64Value
            store.observed = Date()
            store.message = (result["receive_warning"] as? String).map { "Pending receive: " + $0 } ?? "Ark synchronized."
            try await store.refreshActivity()
        }
    }
}

struct OnchainTransactionRow: View {
    @AppStorage("displayUnit") private var unit: BitcoinUnit = .sats
    let item: ActivityItem
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.amountSat > 0 ? "arrow.down.left" : "arrow.up.right")
                .foregroundStyle(PaperclipTheme.orange)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.amountSat > 0 ? "Received" : item.amountSat < 0 ? "Sent" : "Wallet transaction").font(.headline)
                Text(item.status).font(.caption).foregroundStyle(PaperclipTheme.muted)
                if let date = item.date { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(PaperclipTheme.muted) }
                Text(item.id).font(.caption2.monospaced()).lineLimit(1).truncationMode(.middle).foregroundStyle(PaperclipTheme.muted)
            }
            Spacer(minLength: 0)
            Text(unit.signed(item.amountSat)).monospacedDigit()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(PaperclipTheme.muted)
        }.padding(.vertical, 6).contentShape(Rectangle())
    }
}

struct OnchainTransactionView: View {
    @EnvironmentObject var store: WalletStore
    @AppStorage("displayUnit") private var unit: BitcoinUnit = .sats
    let transaction: ActivityItem
    @State private var copied = false
    private var current: ActivityItem { store.activity.first { $0.id == transaction.id } ?? transaction }
    private var explorerURL: URL? {
        guard store.network == "xbt-mainnet", transaction.id.count == 64,
              transaction.id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }) else { return nil }
        return URL(string: "https://mempool.guide/tx/" + transaction.id)
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                WalletSection {
                    Label("On-chain transaction", systemImage: "bitcoinsign.circle").foregroundStyle(PaperclipTheme.muted)
                    Text(unit.signed(current.amountSat)).font(.largeTitle.bold()).minimumScaleFactor(0.6).lineLimit(1)
                    Label(current.status, systemImage: current.status == "Confirmed" ? "checkmark.circle.fill" : "clock")
                        .foregroundStyle(current.status == "Confirmed" ? .green : PaperclipTheme.orange)
                    Text("Net change to your wallet balance, including any transaction fee paid by this wallet. Transfers between your own addresses may show only a fee.")
                        .font(.caption).foregroundStyle(PaperclipTheme.muted)
                }
                WalletSection("Details") {
                    LabeledContent("Network", value: store.network == "xbt-mainnet" ? "XBT mainnet" : "Test network")
                    LabeledContent("Status", value: current.status)
                    if let date = current.date { LabeledContent("Recorded", value: date.formatted(date: .abbreviated, time: .shortened)) }
                    Text("Status reflects the last wallet synchronization.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                    Divider()
                    Text("Transaction ID").font(.subheadline.bold())
                    Text(transaction.id).font(.caption.monospaced()).textSelection(.enabled)
                    Button(copied ? "Copied" : "Copy transaction ID") {
                        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: transaction.id]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
                        copied = true
                    }.buttonStyle(.bordered)
                }
                if let explorerURL {
                    WalletSection {
                        Link(destination: explorerURL) {
                            WalletNavigationRow("View on mempool.guide", subtitle: "Explore confirmations, inputs, outputs, and fees", icon: "arrow.up.right.square")
                        }
                        Text("Opens the public explorer in your browser.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                    }
                }
            }.padding(22)
        }.background(PaperclipTheme.navy).navigationTitle("Transaction").navigationBarTitleDisplayMode(.inline)
    }
}
