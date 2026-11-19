import SwiftUI
import PaperclipMobile

@main struct PaperclipApp: App {
    @Environment(\.scenePhase) private var scene
    @StateObject private var maintenance = Maintenance.shared
    @StateObject private var store = WalletStore()
    @StateObject private var lock = WalletLock()
    @StateObject private var nodePayments = LightningPaymentMonitor.shared
    @StateObject private var bridgePayments = LightningBridgeModel.shared
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("walletLock") private var lockEnabled = true
    init() {
        UserDefaults.standard.register(defaults: ["automaticRefresh": true, "walletLock": true])
        Maintenance.shared.register()
        _ = PaymentNotifications.shared
    }
    var body: some Scene {
        WindowGroup {
            ZStack {
                #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("-build61-preview") { Build61Preview() }
                else if ProcessInfo.processInfo.arguments.contains("-coinjoin-layout-test") {
                    CoinjoinLayoutTestView()
                } else { WalletView().environmentObject(store).environmentObject(maintenance) }
                #else
                WalletView().environmentObject(store).environmentObject(maintenance)
                #endif
                if store.hasWallet && lockEnabled && !lock.unlocked {
                    VStack(spacing: 24) {
                        Image(systemName: "lock.shield").font(.system(size: 56)).foregroundStyle(PaperclipTheme.orange)
                        Text("Your XBT. Your keys.").font(.title.bold())
                        Button("Unlock Paperclip") { Task { await lock.unlock() } }.buttonStyle(WalletPrimaryButtonStyle())
                        Text(lock.error).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).walletPageBackground()
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
                #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("-node-read-probe") {
                    await NodeReadProbe.run()
                    return
                }
                if ProcessInfo.processInfo.arguments.contains("-coinjoin-layout-test") || ProcessInfo.processInfo.arguments.contains("-build61-preview") { return }
                #endif
                await store.load()
                nodePayments.setForeground(true)
                bridgePayments.setForeground(true)
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
                    bridgePayments.setForeground(true)
                    Task {
                        await store.engine.setForeground(true)
                        if store.hasWallet && lockEnabled && !lock.unlocked { await lock.unlock() }
                        if store.hasWallet { await maintenance.update(automatic: UserDefaults.standard.bool(forKey: "automaticRefresh")) }
                    }
                } else if phase == .background { nodePayments.setForeground(false); bridgePayments.setForeground(false); lock.unlocked = false; maintenance.schedule(); Task { await store.engine.setForeground(false) } }
            }
        }
    }
}

struct WalletView: View {
    @EnvironmentObject var store: WalletStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum Tab: Hashable { case wallet, lightning, jars, activity, settings }
    @State private var selectedTab: Tab = .wallet
    var body: some View {
        Group {
            if !store.loaded { ProgressView("Open secure storage…") }
            else if !store.hasWallet { SetupView() }
            else {
                // Stable tab identities prevent SwiftUI falling back to the first tab.
                // Only wallet-scoped navigation is recreated when the account changes.
                TabView(selection: $selectedTab) {
                    ZStack { NavigationStack { DashboardView() }.id(store.walletID) }
                        .tabItem { Label("Wallet", systemImage: "wallet.pass") }.tag(Tab.wallet)
                    NavigationStack { LightningView() }
                        .tabItem { Label("Lightning", systemImage: "bolt.fill") }.tag(Tab.lightning)
                    NavigationStack { JoinBlaketView() }
                        .tabItem { Label("Jars", image: "JarIcon") }.tag(Tab.jars)
                    ZStack { NavigationStack { ActivityView() }.id(store.walletID) }
                        .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }.tag(Tab.activity)
                    ZStack { NavigationStack { SettingsView() }.id(store.walletID) }
                        .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }.tag(Tab.settings)
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selectedTab)
            }
        }.walletPageBackground()
    }
}

struct DashboardView: View {
    @AppStorage("displayUnit") private var unit: BitcoinUnit = .sats
    @EnvironmentObject var store: WalletStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sending = false
    @State private var receiving = false
    @State private var hideBalance = false
    @Environment(\.dynamicTypeSize) private var balanceTextSize
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                WalletColumns(spacing: 14) {
                WalletCard(inset: 18, spacing: 14) {
                    HStack(alignment: .top, spacing: 8) {
                      VStack(alignment: .leading, spacing: 6) {
                        Text("Total balance").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                            .accessibilityHint(store.supportsArk ? "On-chain balance plus available Ark funds" : "Total on-chain balance")
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            WalletBalanceNumber(sats: totalSats, unit: unit, hidden: hideBalance).font(.system(size: 38, weight: .semibold, design: .rounded)).minimumScaleFactor(0.5).lineLimit(1).privacySensitive().contentTransition(.numericText())
                            Text(unit.title).font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                        }
                        USDValue(sats: store.onchain.flatMap { chain in store.supportsArk ? store.ark.map { chain + $0 } : chain }, hidden: hideBalance, mainnet: store.network == "xbt-mainnet")
                      }.frame(maxWidth: .infinity, alignment: .leading)
                      Button { hideBalance.toggle() } label: { Image(systemName: hideBalance ? "eye.slash" : "eye").font(.system(size: 20)).frame(width: 44, height: 44) }.accessibilityLabel("Toggle balance visibility").accessibilityValue(hideBalance ? "Hidden" : "Visible")
                    }
                    if let pending = store.onchainPending, pending > 0 {
                        Label(hideBalance ? "Pending on-chain: ••••" : "Pending on-chain: " + unit.display(pending), systemImage: "clock")
                            .font(.caption).foregroundStyle(PaperclipTheme.muted).privacySensitive()
                    }
                    (balanceTextSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))) {
                        if !store.isWatchOnly {
                            Button { Task { await store.pauseSync(); sending = true } } label: {
                                Label("Send", systemImage: "arrow.up.right").frame(maxWidth: .infinity).padding(14)
                                    .foregroundStyle(.white).background(PaperclipTheme.orange.gradient, in: Capsule())
                                    .shadow(color: PaperclipTheme.orange.opacity(0.18), radius: 12, y: 5)
                            }.buttonStyle(.plain)
                        }
                        Button { Task { await store.pauseSync(); receiving = true } } label: { Label("Receive", systemImage: "arrow.down.left").frame(maxWidth: .infinity) }.modifier(GlassAction())
                    }.font(.headline)
                }
                .background(alignment: .topTrailing) {
                    Image("PaperclipLogo").resizable().scaledToFit().frame(width: 148, height: 148)
                        .opacity(0.09).padding(12).accessibilityHidden(true)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 26).stroke(
                        LinearGradient(colors: [PaperclipTheme.orange.opacity(0.40), .white.opacity(0.06), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                } secondary: {
                WalletCard(inset: 18, spacing: 12) {
                    NavigationLink { OnchainOverviewView() } label: {
                        accountRow("On-chain", subtitle: store.supportsArk ? (store.onchainAccount == "segwit" ? "SegWit" : "Taproot") : "Account balance", icon: "link", amount: store.onchain)
                    }.buttonStyle(.plain)
                    if store.supportsArk {
                        Divider()
                        NavigationLink { ArkOverviewView() } label: {
                            accountRow("Ark", subtitle: "Beta · Available", icon: "square.stack.3d.up", amount: store.ark)
                        }.buttonStyle(.plain)
                    }
                }
                WalletCard(inset: 18, spacing: 10) {
                    HStack {
                        Text("Recent activity").font(.subheadline.weight(.semibold)).foregroundStyle(PaperclipTheme.muted)
                        Spacer(minLength: 12)
                        NavigationLink { ActivityView() } label: {
                            Text("View all").font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                        }.accessibilityLabel("View all activity")
                    }
                    if store.activity.isEmpty {
                        Label("No activity loaded", systemImage: "clock.arrow.circlepath").font(.headline)

                    }
                    ForEach(Array(ActivityItem.newestFirst(store.activity).prefix(1))) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(item.title).font(.subheadline.weight(.medium))
                                Spacer(minLength: 12)
                                Text(hideBalance ? "••••" : unit.signed(item.amountSat)).font(.subheadline).monospacedDigit()
                            }
                            Text(item.status).font(.caption).foregroundStyle(PaperclipTheme.muted)
                        }.privacySensitive()
                    }
                }
                }
                NavigationLink { BuyXBTView() } label: {
                    Label("Buy XBT", systemImage: "plus.circle").font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                }.buttonStyle(.plain)
                if let pending = store.pending, pending > 0 { Label("\(unit.display(pending)) pending", systemImage: "clock").font(.subheadline) }
                if store.observed == nil {
                    NavigationLink { ConnectionsView() } label: { Label("Configure your connection", systemImage: "network") }
                }
                VStack(alignment: .leading, spacing: 6) {
                    if store.busy || !store.message.isEmpty {
                        HStack { if store.busy { ProgressView() }; Text(store.message).font(.caption).foregroundStyle(PaperclipTheme.muted) }
                    }
                    if store.syncing {
                        Button("Pause refresh") { Task { await store.pauseSync() } }
                            .font(.caption.weight(.semibold))
                            .accessibilityHint("Keep cached balances and use the wallet. Payment review checks funds again.")
                    }
                    if store.supportsArk, let date = store.observed { Text("Ark last checked \(date.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.secondary) }
                }
            }.walletPageContent(maxWidth: 1120)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background {
            ZStack {
                PaperclipTheme.navy
                RadialGradient(colors: [PaperclipTheme.orange.opacity(0.10), .clear], center: .topLeading, startRadius: 0, endRadius: 420)
            }.ignoresSafeArea()
        }.navigationBarTitleDisplayMode(.inline)
            .task {
                #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("-build61-preview") { return }
                #endif
                // A switch/add finishes its UI action after the new dashboard appears.
                while store.busy && !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
                guard !Task.isCancelled else { return }
                store.refreshOnAppearance()
                while !Task.isCancelled {
                    await store.refreshCachedArkBalance()
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if let profile = store.selectedProfile {
                        NavigationLink { WalletPickerView() } label: {
                            HStack(spacing: 6) {
                                VStack(spacing: 2) {
                                    Text(profile.name).font(.headline).lineLimit(1)
                                    Text((store.network == "xbt-mainnet" ? "XBT · " : "Regtest · ") + profile.kind.title)
                                        .font(.caption2).foregroundStyle(PaperclipTheme.muted).lineLimit(1)
                                }
                                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                            }.frame(minHeight: 44).contentShape(Rectangle()).foregroundStyle(.primary)
                        }.buttonStyle(.plain).accessibilityLabel("Active wallet: \(profile.name). Switch wallet")
                            .accessibilityValue((store.network == "xbt-mainnet" ? "XBT mainnet. " : "Regtest. ") + profile.kind.title)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await XBTPrice.shared.refresh(force: true) }; store.run { try await store.synchronize() } } label: { Image(systemName: "arrow.clockwise") }.disabled(store.busy).accessibilityLabel("Synchronize wallet")
                }
            }
            .refreshable { store.run { try await store.synchronize() }; await XBTPrice.shared.refresh(force: true) }
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: store.onchain)
            .sheet(isPresented: $sending) { NavigationStack { WalletSendView() } }
            .sheet(isPresented: $receiving) { NavigationStack { ReceiveView() } }
    }
    private var totalSats: UInt64? {
        guard let chain = store.onchain else { return nil }
        if !store.supportsArk { return chain }
        guard let ark = store.ark else { return nil }
        return chain + ark
    }
    private func accountRow(_ title: String, subtitle: String, icon: String, amount: UInt64?) -> some View {
        let layout = balanceTextSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title3).foregroundStyle(PaperclipTheme.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(PaperclipTheme.muted)
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .trailing, spacing: 4) {
              HStack(alignment: .firstTextBaseline, spacing: 4) {
                WalletBalanceNumber(sats: amount, unit: unit, hidden: hideBalance)
                    .font(.title3.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.6).privacySensitive()
                Text(unit.title).font(.caption).foregroundStyle(PaperclipTheme.muted)
              }
                USDValue(sats: amount, hidden: hideBalance, mainnet: store.network == "xbt-mainnet")
                    .font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(PaperclipTheme.muted)
        }.padding(.vertical, 6).contentShape(Rectangle())
    }

}

struct ActivityView: View {
    @AppStorage("displayUnit") private var unit: BitcoinUnit = .sats
    @EnvironmentObject var store: WalletStore
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var filter = "All"
    private var items: [ActivityItem] { store.activity.filter {
        filter == "All" || (filter == "Ark" ? $0.id.hasPrefix("ark-") : !$0.id.hasPrefix("ark-"))
    } }
    var body: some View {
        ScrollView {
          VStack(spacing: 12) {
            Picker("Activity wallet", selection: $filter) {
                Text("All").tag("All"); Text("On-chain").tag("On-chain"); Text("Ark").tag("Ark")
            }.pickerStyle(.segmented)
            if items.isEmpty {
                ContentUnavailableView(store.activity.isEmpty ? "No activity loaded" : "No " + filter.lowercased() + " transactions", systemImage: "clock", description: Text(store.activity.isEmpty ? "Refresh to load your wallet's transaction history." : "Choose All to see transactions from your other accounts."))
            }
            ForEach(items) { item in
                if !item.id.hasPrefix("ark-") {
                    NavigationLink { OnchainTransactionView(transaction: item) } label: {
                        WalletCard(inset: 18, spacing: 8) { OnchainTransactionRow(item: item) }
                    }.buttonStyle(.plain)
                } else {
                    NavigationLink { ArkActivityDetailView(item: item) } label: {
                    WalletCard(inset: 18, spacing: 8) {
                        (textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 12))) {
                            Text(item.title).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                            Text(unit.signed(item.amountSat)).font(.headline).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                        }
                        HStack {
                            Text(item.status).font(.subheadline).foregroundStyle(PaperclipTheme.orange)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(PaperclipTheme.muted).accessibilityHidden(true)
                        }
                        if let date = item.date {
                            Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(PaperclipTheme.muted)
                        }
                    }
                    }.buttonStyle(.plain).accessibilityHint("View transaction details")
                }
            }
            if !store.message.isEmpty { Text(store.message).font(.caption) }
          }.walletPageContent()
        }.scrollContentBackground(.hidden).walletPageBackground().navigationTitle("Activity").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Refresh") { store.run { try await store.refreshActivity() } }.disabled(store.busy) }
    }
}

struct OnchainOverviewView: View {
    @AppStorage("displayUnit") private var unit: BitcoinUnit = .sats
    @EnvironmentObject var store: WalletStore
    @State private var account = "taproot"
    @State private var confirmed: UInt64?
    @State private var unconfirmed: UInt64?
    @State private var immature: UInt64?
    @State private var transactions: [ActivityItem] = []
    @State private var status = "Saved wallet state. Refresh to check the network."
    @State private var loading = false
    var body: some View {
        ScrollView {
          VStack(spacing: 20) {
            if store.selectedProfile?.kind == .hot {
                WalletSection("Address account") {
                    Picker("Address account", selection: Binding(get: { account }, set: { selected in
                        Task {
                            guard !loading, !store.busy else { return }
                            loading = true; store.busy = true
                            defer { loading = false; store.busy = false }
                            do {
                                try await store.engine.selectOnchainAccount(selected)
                                account = selected
                                status = "Account changed. Refresh to discover its balance."
                                await load()
                                store.activity = []
                                try await store.refreshActivity()
                            } catch { status = error.localizedDescription }
                        }
                    })) { Text("Taproot").tag("taproot"); Text("SegWit").tag("segwit") }.pickerStyle(.segmented).disabled(loading || store.busy)
                    Text("Same seed, separate balances. Switching does not move funds. Receive, send, and Ark boarding use the selected account.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                }
            }
            WalletSection("Balance") {
                USDValue(sats: store.onchain, mainnet: store.network == "xbt-mainnet")
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
          }.walletPageContent()
        }.navigationTitle("On-chain")
            .scrollContentBackground(.hidden).walletPageBackground()
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
            if let selected = result["account"] as? String { account = selected; store.onchainAccount = selected }
            confirmed = (result["confirmed_sat"] as? NSNumber)?.uint64Value
            unconfirmed = (result["unconfirmed_sat"] as? NSNumber)?.uint64Value
            immature = (result["immature_sat"] as? NSNumber)?.uint64Value
            store.applyOnchainOverview(result)
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
        loading = true
        store.runSync {
            defer { loading = false }
            do {
                _ = try await store.engine.operation("sync_onchain")
                status = "Updated \(Date().formatted(date: .omitted, time: .shortened))"
            } catch {
                status = "Showing saved state. \(error.localizedDescription)"
                try Task.checkCancellation()
            }
            await load()
        }
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
                WalletSection("Ark balance · Beta") {
                    Text(unit.display(store.ark)).font(.largeTitle.bold()).privacySensitive().contentTransition(.numericText())
                    USDValue(sats: store.ark, mainnet: store.network == "xbt-mainnet")
                    Text("Available to spend").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                    LabeledContent("Pending", value: unit.display(store.pending))
                    HStack {
                        Button { sending = true } label: { Label("Pay", systemImage: "arrow.up.right").frame(maxWidth: .infinity) }.modifier(GlassAction())
                        Button { receiving = true } label: { Label("Receive", systemImage: "arrow.down.left").frame(maxWidth: .infinity) }.modifier(GlassAction())
                    }
                    Text("Pending funds are not yet available. Keep the app open to finish incoming Lightning payments.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                }
                WalletSection {
                    NavigationLink { LightningBridgeView(source: .ark) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            WalletNavigationRow("Pay Spamcoin (BTC)", subtitle: "Use Ark through Paperclip Bridge", icon: "arrow.left.arrow.right")
                            BridgeStatusBadge(direction: .paySpamcoin)
                        }
                    }.buttonStyle(.plain)
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
            }.walletPageContent()
        }.walletPageBackground().navigationTitle("Ark · Beta")
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
            if let warning = result["recovery_warning"] as? String {
                store.message += "\nArk recovery registration will retry: " + warning
            }
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
                WalletAmountHero(amount: unit.signed(current.amountSat), caption: "Balance change", detail: "On-chain transaction",
                    symbol: current.amountSat > 0 ? "arrow.down.left" : current.amountSat < 0 ? "arrow.up.right" : "arrow.left.arrow.right")
                WalletSection {
                    Label(current.status, systemImage: current.status == "Confirmed" ? "checkmark.circle.fill" : "clock")
                        .foregroundStyle(current.status == "Confirmed" ? .green : PaperclipTheme.orange)
                    Text("Net change to your wallet balance, including any transaction fee paid by this wallet. Transfers between your own addresses may show only a fee.")
                        .font(.caption).foregroundStyle(PaperclipTheme.muted)
                }
                WalletSection("Details") {
                    WalletReviewDetail(title: "Network", value: store.network == "xbt-mainnet" ? "XBT mainnet" : "Test network")
                    WalletReviewDetail(title: "Status", value: current.status)
                    if let date = current.date { WalletReviewDetail(title: "Recorded", value: date.formatted(date: .abbreviated, time: .shortened)) }
                    Text("Status reflects the last wallet synchronization.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                    Divider()
                    Text("Transaction ID").font(.subheadline.bold())
                    Text(transaction.id).font(.caption.monospaced()).textSelection(.enabled)
                    Button(copied ? "Copied" : "Copy transaction ID") {
                        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: transaction.id]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
                        copied = true
                    }.buttonStyle(.bordered)
                }
                if current.status != "Confirmed" {
                    WalletSection("Payment assistance") {
                        Text("An unconfirmed payment is still in progress. Do not send it again.")
                        Button("Refresh status") { store.run { try await store.refreshActivity() } }.disabled(store.busy)
                        if current.amountSat < 0 && !store.isHardware && !store.isWatchOnly {
                            FeeReplacementControl(txid: transaction.id)
                        }
                    }
                }
                if let explorerURL {
                    WalletSection {
                        Link(destination: explorerURL) {
                            WalletNavigationRow("View on mempool.guide", subtitle: "Explore confirmations, inputs, outputs, and fees", icon: "arrow.up.right.square")
                        }
                        Text("Opens the public explorer in your browser.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                    }
                }
            }.walletPageContent()
        }.walletPageBackground().navigationTitle("Transaction").navigationBarTitleDisplayMode(.inline)
    }
}

private struct FeeReplacementControl: View {
    @EnvironmentObject var store: WalletStore
    let txid: String
    @State private var review: [String: Any]?
    @State private var owner = ""
    @State private var result = ""
    @State private var fee = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Increase the fee from this payment’s change. The recipient and amount stay the same.").font(.subheadline)
            DisclosureGroup("Custom total fee") {
                TextField("Total fee in sats (optional)", text: $fee).keyboardType(.numberPad).disabled(store.busy)
                Text("Leave blank to review twice the original fee. This does not guarantee a confirmation time.").font(.caption)
            }
            Button("Review fee increase") {
                review = nil; result = ""; owner = store.walletID
                store.run {
                    let value = fee.isEmpty ? UInt64(0) : UInt64(fee)
                    guard let value, fee.isEmpty || fee.utf8.allSatisfy({ (48...57).contains($0) }) else { throw WalletFailure(message: "Enter the total fee in whole sats.") }
                    let response = try await store.engine.operation("replacement_prepare", fields: ["txid": txid, "new_fee_sat": value])
                    guard owner == store.walletID else { return }
                    do { try FeeReplacementReview.validate(JSONSerialization.data(withJSONObject: response), expectedTransaction: txid) }
                    catch { throw WalletFailure(message: "The fee review is incomplete. No replacement was submitted.") }
                    review = response
                }
            }.disabled(store.busy)
            if let data = review {
                Divider()
                Text("Review fee replacement").font(.headline)
                ForEach(Array((data["recipients"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, recipient in
                    Text(recipient["address"] as? String ?? "").font(.caption.monospaced()).textSelection(.enabled)
                    Text("Recipient: " + String((recipient["amount_sat"] as? NSNumber)?.uint64Value ?? 0) + " sats")
                }
                LabeledContent("Original fee", value: sats(data["old_fee_sat"]))
                LabeledContent("New total fee", value: sats(data["new_fee_sat"]))
                LabeledContent("Additional debit", value: sats(data["additional_fee_sat"]))
                Text("This replaces the existing transaction. Confirmation is still required.").font(.caption)
                HStack {
                    Button("Cancel") { review = nil }
                    Button("Increase fee") {
                        review = nil
                        store.run {
                            guard owner == store.walletID else { throw WalletFailure(message: "Wallet changed. Review again.") }
                            let response = try await store.engine.operation("replacement_commit", fields: ["replacement_txid": data["replacement_txid"] ?? "", "new_fee_sat": data["new_fee_sat"] ?? 0])
                            result = (response["state"] as? String == "submitted" ? "Replacement submitted. Awaiting confirmation." : "Replacement saved. Broadcast is not confirmed; check status before another action.") + "\n" + (response["txid"] as? String ?? "")
                            try await store.refreshActivity()
                        }
                    }.disabled(store.busy || owner != store.walletID)
                }
            }
            if !result.isEmpty { Text(result).font(.caption).textSelection(.enabled) }
            Text(store.message).font(.caption).foregroundStyle(PaperclipTheme.muted)
        }.onChange(of: fee) { _, _ in review = nil }
         .onChange(of: store.walletID) { _, _ in review = nil; result = "" }
         .onChange(of: store.onchainAccount) { _, _ in review = nil; result = "" }
    }
    private func sats(_ value: Any?) -> String { (value as? NSNumber).map { "\($0.uint64Value) sats" } ?? "Unavailable" }
}
