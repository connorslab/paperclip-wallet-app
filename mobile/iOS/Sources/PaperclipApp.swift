import SwiftUI
import PaperclipMobile

@main struct PaperclipApp: App {
    @Environment(\.scenePhase) private var scene
    @StateObject private var maintenance = Maintenance.shared
    @StateObject private var store = WalletStore()
    @StateObject private var lock = WalletLock()
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
            .tint(PaperclipTheme.orange).preferredColorScheme(.dark)
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-tor-probe") {
                    await TorProbe.run()
                    return
                }
                #endif
                await store.load()
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
                    Task {
                        await store.engine.setForeground(true)
                        if store.hasWallet && lockEnabled && !lock.unlocked { await lock.unlock() }
                        if store.hasWallet { await maintenance.update(automatic: UserDefaults.standard.bool(forKey: "automaticRefresh")) }
                    }
                } else if phase == .background { lock.unlocked = false; maintenance.schedule(); Task { await store.engine.setForeground(false) } }
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
                    NavigationStack { LightningView() }.tabItem { Label("Lightning", systemImage: "bolt.fill") }
                    NavigationStack { ActivityView() }.tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }
                    NavigationStack { SettingsView() }.tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
                }
            }
        }.background(PaperclipTheme.navy)
    }
}

struct DashboardView: View {
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
                    Label(store.network == "xbt-mainnet" ? "XBT MAINNET" : "REGTEST", systemImage: "circle.fill").font(.caption2).tracking(2)
                    Spacer()
                    Button { hideBalance.toggle() } label: { Image(systemName: hideBalance ? "eye.slash" : "eye") }.accessibilityLabel("Toggle balance visibility")
                }.foregroundStyle(PaperclipTheme.muted)
                WalletCard {
                    Text("Your XBT.\nWithin reach.").font(.largeTitle.bold())
                    Text(total).font(.system(size: 42, weight: .semibold, design: .rounded)).minimumScaleFactor(0.5).lineLimit(1).privacySensitive()
                        .contentTransition(.numericText())
                    Text("SATS · ON-CHAIN + ARK").font(.caption2).tracking(2).foregroundStyle(PaperclipTheme.muted)
                    HStack(spacing: 12) {
                        Button { sending = true } label: { Label("Send", systemImage: "arrow.up.right").frame(maxWidth: .infinity) }.modifier(GlassAction())
                        Button { receiving = true } label: { Label("Receive", systemImage: "arrow.down.left").frame(maxWidth: .infinity) }.modifier(GlassAction())
                    }.font(.headline)
                }
                HStack(spacing: 14) {
                    NavigationLink { OnchainOverviewView() } label: {
                        balanceCard("On-chain", icon: "link", amount: store.onchain)
                    }.buttonStyle(.plain).accessibilityHint("View on-chain balances and transactions")
                    balanceCard("Ark", icon: "square.stack.3d.up", amount: store.ark)
                }
                if let pending = store.pending, pending > 0 { Label("\(pending.formatted()) sats pending", systemImage: "clock").font(.subheadline) }
                NavigationLink { ArkToolsView() } label: {
                    WalletCard {
                        HStack { Image(systemName: "square.stack.3d.up.fill").foregroundStyle(PaperclipTheme.orange); Text("Ark with Paperclip").font(.headline); Spacer(); Image(systemName: "chevron.right") }
                        Text("Board, offboard, receive Lightning, and manage recovery.").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                    }
                }.buttonStyle(.plain)
                if store.observed == nil {
                    NavigationLink { ConnectionsView() } label: { Label("Configure your connection", systemImage: "network") }
                }
                HStack { if store.busy { ProgressView() }; Text(store.message).font(.caption).foregroundStyle(PaperclipTheme.muted) }
                if let date = store.observed { Text("Ark last checked \(date.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.secondary) }
            }.padding(22)
        }.background(PaperclipTheme.navy).navigationBarTitleDisplayMode(.inline)
            .toolbar { Button { store.run { try await store.synchronize() } } label: { Image(systemName: "arrow.clockwise") }.disabled(store.busy).accessibilityLabel("Synchronize wallet") }
            .refreshable { guard !store.busy else { return }; store.run { try await store.synchronize() } }
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: store.onchain)
            .sheet(isPresented: $sending) { NavigationStack { SendView() } }
            .sheet(isPresented: $receiving) { NavigationStack { ReceiveView() } }
    }
    private var total: String {
        if hideBalance { return "••••••" }
        guard let chain = store.onchain, let ark = store.ark else { return "—" }
        return (chain + ark).formatted()
    }
    private func balanceCard(_ title: String, icon: String, amount: UInt64?) -> some View {
        WalletCard {
            Label(title, systemImage: icon).font(.subheadline).foregroundStyle(PaperclipTheme.muted)
            Text(hideBalance ? "••••" : amount.map { $0.formatted() } ?? "—").font(.title2.bold()).lineLimit(1).minimumScaleFactor(0.6).privacySensitive()
            Text("sats").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ActivityView: View {
    @EnvironmentObject var store: WalletStore
    var body: some View {
        List {
            if store.activity.isEmpty { ContentUnavailableView("No activity loaded", systemImage: "clock", description: Text("Synchronize your wallet to load transactions.")) }
            ForEach(store.activity) { item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(item.title).font(.headline); Spacer(); Text(item.amount).monospacedDigit() }
                    Text(item.status).foregroundStyle(PaperclipTheme.orange)
                    Text(item.detail).font(.caption2.monospaced()).textSelection(.enabled)
                }.padding(.vertical, 8).listRowBackground(PaperclipTheme.panel)
            }
            Text(store.message).font(.caption)
        }.scrollContentBackground(.hidden).background(PaperclipTheme.navy).navigationTitle("Activity")
            .toolbar { Button("Refresh") { store.run { try await store.refreshActivity() } }.disabled(store.busy) }
    }
}

struct OnchainOverviewView: View {
    @EnvironmentObject var store: WalletStore
    @State private var confirmed: UInt64?
    @State private var unconfirmed: UInt64?
    @State private var immature: UInt64?
    @State private var transactions: [ActivityItem] = []
    @State private var status = "Saved wallet state. Refresh to check the network."
    @State private var loading = false
    var body: some View {
        List {
            Section("Balance") {
                LabeledContent("Confirmed", value: sats(confirmed))
                LabeledContent("Unconfirmed", value: sats(unconfirmed))
                if let immature, immature > 0 { LabeledContent("Immature mining rewards", value: sats(immature)) }
                Text("Unconfirmed includes pending incoming outputs and change. Amounts reflect the wallet's unspent outputs.").font(.caption)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Section { NavigationLink("Receive & change addresses") { OnchainAddressesView() } }
            Section("On-chain transactions") {
                if transactions.isEmpty { Text("No on-chain transactions in the saved wallet state.").foregroundStyle(.secondary) }
                ForEach(transactions) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(item.status).foregroundStyle(PaperclipTheme.orange); Spacer(); Text(item.amount).monospacedDigit() }
                        Text(item.detail).font(.caption.monospaced()).textSelection(.enabled)
                        Button("Copy transaction ID") {
                            UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: item.id]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
                        }.buttonStyle(.borderless)
                    }.padding(.vertical, 6)
                }
            }
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
    private func sats(_ amount: UInt64?) -> String { amount.map { "\($0.formatted()) sats" } ?? "—" }
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
                    amount: "\(amount.int64Value.formatted()) sats", detail: txid)
            }
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
