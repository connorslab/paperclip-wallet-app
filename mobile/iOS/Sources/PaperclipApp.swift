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
                    balanceCard("On-chain", icon: "link", amount: store.onchain)
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
